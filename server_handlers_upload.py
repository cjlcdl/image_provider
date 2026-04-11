import cgi
import mimetypes
import shutil
import uuid
from http import HTTPStatus
from typing import Any, Dict, Optional, Tuple, cast

import server_state as state
from config import FILE_ROUTE_PREFIX, MAX_UPLOAD_BYTES, PERMANENT_TOKEN_HEADER, RESUMABLE_UPLOAD_CHUNK_SIZE_HINT, UPLOAD_SESSION_MAX_AGE_SECONDS
from folder_index import folder_requires_password, get_folder
from server_auth import validate_permanent_token
from server_storage import (
    build_upload_session_record,
    is_ip_blacklisted,
    is_rate_limited,
    is_upload_session_expired,
    load_upload_session_record,
    remove_upload_session_files,
    resolve_relative_path,
    save_upload_session_record,
    upload_session_metadata_path,
    upload_session_part_path,
    upsert_file_index_record,
)
from server_utils import (
    extract_allowed_extension,
    get_uploaded_file_content_type,
    is_valid_boundary,
    normalize_folder_id,
    normalize_uploaded_filename,
    now_local,
    sanitize_index_name,
    stream_upload_to_path,
)


class UploadHandlerMixin:
    def parse_resumable_upload_path(self, request_path: str) -> Tuple[Optional[str], Optional[str]]:
        prefix = "/api/upload/resumable/"
        if not request_path.startswith(prefix):
            return None, None

        suffix = request_path[len(prefix) :].strip("/")
        if not suffix:
            return None, None

        parts = suffix.split("/")
        if len(parts) == 1 and state.UPLOAD_SESSION_ID_PATTERN.fullmatch(parts[0]):
            return parts[0], "session"
        if len(parts) == 2 and parts[1] == "complete" and state.UPLOAD_SESSION_ID_PATTERN.fullmatch(parts[0]):
            return parts[0], "complete"
        return None, None

    def load_authorized_upload_session(self, upload_id: str) -> Optional[Dict[str, Any]]:
        if not state.UPLOAD_SESSION_ID_PATTERN.fullmatch(upload_id):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40026, "invalid resumable upload id")
            return None

        upload_token = self.headers.get(state.UPLOAD_SESSION_TOKEN_HEADER, "").strip()
        if not upload_token:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40027, "missing upload token")
            return None

        with state.upload_session_lock:
            record = load_upload_session_record(upload_id)
            if record is None or is_upload_session_expired(record):
                remove_upload_session_files(upload_id)
                self.send_error_json(HTTPStatus.NOT_FOUND, 40402, "upload session not found")
                return None

            if str(record.get("uploadToken", "")) != upload_token:
                self.send_error_json(HTTPStatus.UNAUTHORIZED, 40104, "invalid upload token")
                return None

            return dict(record)

    def resolve_upload_mode(self) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
        token_value = self.headers.get(PERMANENT_TOKEN_HEADER, "").strip()
        if not token_value:
            return "temporary", None

        is_valid, token_payload, code, message = validate_permanent_token(token_value)
        if not is_valid:
            self.close_connection = True
            status = HTTPStatus.UNAUTHORIZED if code < 50000 else HTTPStatus.INTERNAL_SERVER_ERROR
            self.send_error_json(status, code, message)
            return None, None

        return "permanent", token_payload

    def handle_resumable_upload_init(self) -> None:
        client_ip = self.client_address[0]
        if is_ip_blacklisted(client_ip):
            self.close_connection = True
            self.send_error_json(HTTPStatus.FORBIDDEN, 40301, "ip is blocked")
            return

        if is_rate_limited(client_ip):
            self.send_error_json(HTTPStatus.TOO_MANY_REQUESTS, 42900, "too many upload requests")
            return

        payload = self.read_json_body()
        if payload is None:
            return

        total_size = payload.get("size")
        if isinstance(total_size, str) and total_size.isdigit():
            total_size = int(total_size)
        if not isinstance(total_size, int) or total_size < 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40024, "invalid upload size")
            return
        if total_size > MAX_UPLOAD_BYTES:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 41301, "file too large")
            return

        raw_filename = payload.get("filename")
        raw_mime_type = payload.get("mimeType")
        requested_folder_id = normalize_folder_id(payload.get("folderId"))
        provided_filename = raw_filename if isinstance(raw_filename, str) else ""
        provided_mime_type = raw_mime_type if isinstance(raw_mime_type, str) else ""

        if requested_folder_id:
            folder_record = get_folder(requested_folder_id)
            if folder_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                return
            if folder_requires_password(folder_record):
                if self.require_folder_password(requested_folder_id) is None:
                    return

        upload_mode, token_payload = self.resolve_upload_mode()
        if upload_mode is None:
            return

        normalized_uploaded_filename = normalize_uploaded_filename(provided_filename, provided_mime_type)
        indexed_name = sanitize_index_name(normalized_uploaded_filename)
        if indexed_name is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40019, "invalid indexed name")
            return

        extension = extract_allowed_extension(normalized_uploaded_filename) or ""
        mime_type = provided_mime_type.strip() or mimetypes.guess_type(normalized_uploaded_filename)[0] or "application/octet-stream"

        if upload_mode == "permanent":
            if token_payload is None:
                self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, 50000, "internal server error")
                return
            file_name = "{}_{}{}".format(token_payload["ts"], token_payload["nonce"], extension)
            relative_url = "{}/permanent/{}".format(FILE_ROUTE_PREFIX, file_name)
        else:
            folder_name = now_local().strftime("%Y%m%d")
            file_name = "{}{}".format(uuid.uuid4().hex, extension)
            relative_url = "{}/{}/{}".format(FILE_ROUTE_PREFIX, folder_name, file_name)

        with state.upload_session_lock:
            record = build_upload_session_record(
                storage_type=upload_mode,
                indexed_name=indexed_name,
                system_name=file_name,
                relative_path=relative_url,
                total_size=total_size,
                mime_type=mime_type,
                folder_id=requested_folder_id,
            )
            save_upload_session_record(record)

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "upload session created",
                "data": {
                    "uploadId": record["uploadId"],
                    "uploadToken": record["uploadToken"],
                    "storage": upload_mode,
                    "path": relative_url,
                    "url": relative_url,
                    "name": file_name,
                    "indexedName": indexed_name,
                    "mimeType": mime_type,
                    "folderId": requested_folder_id,
                    "totalSize": total_size,
                    "uploadedBytes": 0,
                    "chunkSizeHint": RESUMABLE_UPLOAD_CHUNK_SIZE_HINT,
                    "expiresIn": UPLOAD_SESSION_MAX_AGE_SECONDS,
                },
            },
        )
        self.write_audit_log(
            action_type="resumable_init",
            indexed_name=indexed_name,
            file_path=relative_url,
            extra={"storage": upload_mode, "totalSize": total_size},
        )

    def handle_resumable_upload_status(self, upload_id: str) -> None:
        record = self.load_authorized_upload_session(upload_id)
        if record is None:
            return

        uploaded_bytes = int(record.get("uploadedSize", 0))
        total_size = int(record.get("totalSize", 0))
        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "ok",
                "data": {
                    "uploadId": record["uploadId"],
                    "storage": record["storage"],
                    "path": record["relativePath"],
                    "url": record["relativePath"],
                    "name": record["systemName"],
                    "indexedName": record["indexedName"],
                    "mimeType": record["mimeType"],
                    "folderId": record.get("folderId"),
                    "totalSize": total_size,
                    "uploadedBytes": uploaded_bytes,
                    "complete": uploaded_bytes >= total_size,
                },
            },
        )
        self.write_audit_log(
            action_type="resumable_status",
            indexed_name=str(record["indexedName"]),
            file_path=str(record["relativePath"]),
            extra={"uploadedBytes": uploaded_bytes, "totalSize": total_size},
        )

    def handle_resumable_upload_chunk(self, upload_id: str) -> None:
        client_ip = self.client_address[0]
        if is_ip_blacklisted(client_ip):
            self.close_connection = True
            self.send_error_json(HTTPStatus.FORBIDDEN, 40301, "ip is blocked")
            return

        record = self.load_authorized_upload_session(upload_id)
        if record is None:
            return

        offset_header = self.headers.get(state.UPLOAD_OFFSET_HEADER, "").strip()
        if not offset_header:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40028, "missing upload offset")
            return
        try:
            offset = int(offset_header)
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40028, "invalid upload offset")
            return

        content_length = self.headers.get("Content-Length", "").strip()
        if not content_length:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40001, "missing content length")
            return
        try:
            content_length_value = int(content_length)
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return
        if content_length_value <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return

        uploaded_bytes = int(record.get("uploadedSize", 0))
        total_size = int(record.get("totalSize", 0))
        if offset != uploaded_bytes or offset + content_length_value > total_size:
            self.send_json(
                HTTPStatus.CONFLICT,
                {
                    "code": 40901,
                    "message": "upload offset mismatch",
                    "data": {"uploadedBytes": uploaded_bytes, "totalSize": total_size},
                },
            )
            return

        part_path = upload_session_part_path(upload_id)
        part_path.parent.mkdir(parents=True, exist_ok=True)
        bytes_read = 0
        with part_path.open("ab") as file_obj:
            while bytes_read < content_length_value:
                chunk = self.rfile.read(min(state.UPLOAD_CHUNK_SIZE, content_length_value - bytes_read))
                if not chunk:
                    break
                file_obj.write(chunk)
                bytes_read += len(chunk)

        actual_size = part_path.stat().st_size if part_path.exists() else uploaded_bytes
        with state.upload_session_lock:
            latest_record = load_upload_session_record(upload_id)
            if latest_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40402, "upload session not found")
                return
            latest_record["uploadedSize"] = actual_size
            latest_record["updatedAt"] = now_local().isoformat()
            save_upload_session_record(latest_record)

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "chunk accepted",
                "data": {
                    "uploadId": upload_id,
                    "uploadedBytes": actual_size,
                    "totalSize": total_size,
                    "complete": actual_size >= total_size,
                },
            },
        )
        self.write_audit_log(
            action_type="resumable_chunk",
            indexed_name=str(record["indexedName"]),
            file_path=str(record["relativePath"]),
            extra={"chunkBytes": bytes_read, "uploadedBytes": actual_size, "totalSize": total_size},
        )

    def handle_resumable_upload_complete(self, upload_id: str) -> None:
        record = self.load_authorized_upload_session(upload_id)
        if record is None:
            return

        total_size = int(record.get("totalSize", 0))
        uploaded_bytes = int(record.get("uploadedSize", 0))
        if uploaded_bytes < total_size:
            self.send_json(
                HTTPStatus.CONFLICT,
                {
                    "code": 40902,
                    "message": "upload is incomplete",
                    "data": {"uploadedBytes": uploaded_bytes, "totalSize": total_size},
                },
            )
            return

        resolved = resolve_relative_path(str(record["relativePath"]))
        if resolved is None:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, 50000, "internal server error")
            return

        storage_type, target_path, normalized_path = resolved
        target_path.parent.mkdir(parents=True, exist_ok=True)
        part_path = upload_session_part_path(upload_id)
        if total_size == 0:
            target_path.touch(exist_ok=True)
        elif not part_path.exists() or part_path.stat().st_size < total_size:
            self.send_json(
                HTTPStatus.CONFLICT,
                {
                    "code": 40902,
                    "message": "upload is incomplete",
                    "data": {
                        "uploadedBytes": part_path.stat().st_size if part_path.exists() else 0,
                        "totalSize": total_size,
                    },
                },
            )
            return
        else:
            shutil.move(str(part_path), str(target_path))
        upsert_file_index_record(
            storage_type=storage_type,
            relative_path=normalized_path,
            system_name=str(record["systemName"]),
            indexed_name=str(record["indexedName"]),
            file_size=target_path.stat().st_size,
            mime_type=str(record.get("mimeType") or "application/octet-stream"),
            folder_id=normalize_folder_id(record.get("folderId")),
        )
        upload_session_metadata_path(upload_id).unlink(missing_ok=True)

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "upload succeeded",
                "data": {
                    "path": normalized_path,
                    "url": normalized_path,
                    "size": target_path.stat().st_size,
                    "storage": storage_type,
                    "name": str(record["systemName"]),
                    "indexedName": str(record["indexedName"]),
                    "mimeType": str(record.get("mimeType") or "application/octet-stream"),
                    "folderId": record.get("folderId"),
                },
            },
        )
        self.write_audit_log(
            action_type="upload_file",
            indexed_name=str(record["indexedName"]),
            file_path=normalized_path,
            extra={"storage": storage_type, "resumable": True},
        )

    def handle_resumable_upload_cancel(self, upload_id: str) -> None:
        record = self.load_authorized_upload_session(upload_id)
        if record is None:
            return

        with state.upload_session_lock:
            remove_upload_session_files(upload_id)

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "upload session canceled",
                "data": {
                    "uploadId": upload_id,
                    "path": str(record["relativePath"]),
                    "indexedName": str(record["indexedName"]),
                },
            },
        )
        self.write_audit_log(
            action_type="resumable_cancel",
            indexed_name=str(record["indexedName"]),
            file_path=str(record["relativePath"]),
        )

    def handle_upload(self) -> None:
        client_ip = self.client_address[0]
        if is_ip_blacklisted(client_ip):
            self.close_connection = True
            self.send_error_json(HTTPStatus.FORBIDDEN, 40301, "ip is blocked")
            return

        if is_rate_limited(client_ip):
            self.send_error_json(HTTPStatus.TOO_MANY_REQUESTS, 42900, "too many upload requests")
            return

        upload_mode, token_payload = self.resolve_upload_mode()
        if upload_mode is None:
            return

        transfer_encoding = self.headers.get("Transfer-Encoding", "")
        if transfer_encoding and transfer_encoding.lower() != "identity":
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40006, "transfer encoding is not supported")
            return

        content_type = self.headers.get("Content-Type", "")
        media_type, content_type_params = cgi.parse_header(content_type)
        if media_type != "multipart/form-data":
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40000, "content type must be multipart/form-data")
            return

        boundary = content_type_params.get("boundary", "")
        if not is_valid_boundary(boundary):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40007, "invalid multipart boundary")
            return

        content_length = self.headers.get("Content-Length")
        if not content_length:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40001, "missing content length")
            return

        try:
            content_length_value = int(content_length)
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return

        if content_length_value <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return

        if content_length_value > state.MAX_REQUEST_BYTES:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 41300, "request body too large")
            return

        try:
            form = cgi.FieldStorage(
                fp=cast(Any, self.rfile),
                headers=self.headers,
                environ={
                    "REQUEST_METHOD": "POST",
                    "CONTENT_TYPE": content_type,
                    "CONTENT_LENGTH": content_length,
                },
            )
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40008, "malformed multipart body")
            return
        except OSError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40008, "malformed multipart body")
            return

        form_items = form.list or []
        field_names = set(item.name for item in form_items if item.name)
        if not form_items or not field_names:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40003, "missing file field")
            return

        if not field_names.issubset({"file", "folderId"}):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40009, "unexpected form fields")
            return

        file_fields = [item for item in form_items if item.name == "file"]
        if len(file_fields) != 1:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40010, "only one file field is allowed")
            return

        folder_field_values = [
            item.value.strip()
            for item in form_items
            if item.name == "folderId" and isinstance(item.value, str) and item.value.strip()
        ]
        if len(folder_field_values) > 1:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40031, "invalid folder id")
            return
        requested_folder_id = normalize_folder_id(folder_field_values[0]) if folder_field_values else None
        if requested_folder_id:
            folder_record = get_folder(requested_folder_id)
            if folder_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                return
            if folder_requires_password(folder_record):
                if self.require_folder_password(requested_folder_id) is None:
                    return

        uploaded_file = file_fields[0]
        if not getattr(uploaded_file, "file", None):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40002, "invalid file field")
            return

        normalized_uploaded_filename = normalize_uploaded_filename(
            uploaded_file.filename,
            get_uploaded_file_content_type(uploaded_file),
        )

        indexed_name = sanitize_index_name(normalized_uploaded_filename)
        if indexed_name is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40019, "invalid indexed name")
            return

        extension = extract_allowed_extension(normalized_uploaded_filename) or ""

        if upload_mode == "permanent":
            if token_payload is None:
                self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, 50000, "internal server error")
                return
            file_name = "{}_{}{}".format(token_payload["ts"], token_payload["nonce"], extension)
            target_dir = state.PERMANENT_UPLOAD_ROOT
            relative_url = "{}/permanent/{}".format(FILE_ROUTE_PREFIX, file_name)
        else:
            folder_name = now_local().strftime("%Y%m%d")
            file_name = "{}{}".format(uuid.uuid4().hex, extension)
            target_dir = state.TEMP_UPLOAD_ROOT / folder_name
            relative_url = "{}/{}/{}".format(FILE_ROUTE_PREFIX, folder_name, file_name)

        target_dir.mkdir(parents=True, exist_ok=True)
        saved_path = target_dir / file_name

        try:
            file_size = stream_upload_to_path(uploaded_file.file, saved_path)
        except ValueError:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 41301, "file too large")
            return
        except OSError:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, 50000, "internal server error")
            return

        mime_type = mimetypes.guess_type(saved_path.name)[0] or "application/octet-stream"
        upsert_file_index_record(
            storage_type=upload_mode,
            relative_path=relative_url,
            system_name=file_name,
            indexed_name=indexed_name,
            file_size=file_size,
            mime_type=mime_type,
            folder_id=requested_folder_id,
        )

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "upload succeeded",
                "data": {
                    "path": relative_url,
                    "url": relative_url,
                    "size": file_size,
                    "storage": upload_mode,
                    "name": file_name,
                    "indexedName": indexed_name,
                    "mimeType": mime_type,
                    "folderId": requested_folder_id,
                },
            },
        )
        self.write_audit_log(
            action_type="upload_file",
            indexed_name=indexed_name,
            file_path=relative_url,
            extra={"storage": upload_mode},
        )