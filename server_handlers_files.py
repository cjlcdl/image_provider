import mimetypes
import shutil
from http import HTTPStatus
from typing import Tuple

import server_state as state
from folder_index import folder_requires_password, get_folder, validate_download_token
from server_storage import (
    apply_file_filters,
    delete_file_by_relative_path,
    get_file_index_record,
    list_all_files,
    move_file_by_relative_path,
    paginate_files,
    remove_file_index_record,
    rename_file_index_record,
    resolve_relative_path,
    upsert_file_index_record,
)
from server_utils import (
    build_content_disposition,
    folder_allows_direct_download,
    is_inline_mime_type,
    normalize_folder_id,
    sanitize_index_name,
)


class FileManagementHandlerMixin:
    def get_file_audit_info(self, relative_path: str) -> Tuple[str, str]:
        resolved = resolve_relative_path(relative_path)
        if resolved is None:
            return "", relative_path

        storage_type, target_path, normalized_path = resolved
        record = get_file_index_record(storage_type, normalized_path) or {}
        indexed_name = str(record.get("indexedName") or target_path.name)
        return indexed_name, normalized_path

    def handle_list_files(self) -> None:
        if not self.authorize_management_request():
            return

        storage_filter = self.get_query_value("storage")
        if storage_filter and storage_filter not in ("temporary", "permanent"):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40020, "invalid storage filter")
            return

        page = self.parse_positive_int_query("page", 1, 40021, "invalid page number")
        if page is None:
            return

        page_size = self.parse_positive_int_query("pageSize", 50, 40022, "invalid page size")
        if page_size is None:
            return

        page_size = min(page_size, 200)
        keyword = self.get_query_value("keyword")
        mime_type = self.get_query_value("mimeType")
        extension = self.get_query_value("extension")
        raw_folder_id = self.get_query_value("folderId")
        folder_id_filter = None
        if raw_folder_id is not None:
            if raw_folder_id == "root":
                folder_id_filter = "root"
            else:
                folder_id_filter = normalize_folder_id(raw_folder_id)
                if not folder_id_filter:
                    self.send_error_json(HTTPStatus.BAD_REQUEST, 40031, "missing folder id")
                    return
                folder_record = get_folder(folder_id_filter)
                if folder_record is None:
                    self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                    return
                if folder_requires_password(folder_record):
                    if self.require_folder_password(folder_id_filter) is None:
                        return

        files = apply_file_filters(
            list_all_files(),
            storage_filter=storage_filter,
            keyword=keyword,
            mime_type=mime_type,
            extension=extension,
            folder_id=folder_id_filter,
        )
        paged_files, total = paginate_files(files, page, page_size)
        total_pages = (total + page_size - 1) // page_size if total else 0

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "ok",
                "data": {
                    "total": total,
                    "page": page,
                    "pageSize": page_size,
                    "returned": len(paged_files),
                    "totalPages": total_pages,
                    "filters": {
                        "storage": storage_filter,
                        "keyword": keyword,
                        "mimeType": mime_type,
                        "extension": extension.lower().lstrip(".") if extension else None,
                        "folderId": folder_id_filter,
                    },
                    "files": paged_files,
                },
            },
        )
        self.write_audit_log(
            action_type="list_files",
            extra={
                "indexedName": "",
                "filePath": "",
                "resultCount": len(paged_files),
                "page": page,
                "pageSize": page_size,
            },
        )

    def handle_delete_file(self) -> None:
        if not self.authorize_management_request():
            return

        path_values = [value for value in self.request_query().get("path", []) if value]
        if path_values:
            relative_paths = path_values
        else:
            relative_paths = []
            content_length = self.headers.get("Content-Length", "").strip()
            if content_length and content_length != "0":
                payload = self.read_json_body()
                if payload is None:
                    return

                if isinstance(payload.get("path"), str) and payload.get("path"):
                    relative_paths = [payload["path"]]
                elif isinstance(payload.get("paths"), list):
                    relative_paths = [item for item in payload.get("paths", []) if isinstance(item, str) and item]

        if not relative_paths:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40017, "missing file path")
            return

        normalized_paths = []
        seen_paths = set()
        for relative_path in relative_paths:
            if relative_path in seen_paths:
                continue
            seen_paths.add(relative_path)
            normalized_paths.append(relative_path)

        deleted_items = []
        missing_items = []
        for relative_path in normalized_paths:
            indexed_name, normalized_path = self.get_file_audit_info(relative_path)
            deleted, result = delete_file_by_relative_path(relative_path)
            if deleted:
                result["indexedName"] = indexed_name
                result["path"] = normalized_path or result.get("path", relative_path)
                deleted_items.append(result)
            else:
                missing_items.append(result)

        if len(normalized_paths) == 1 and not deleted_items:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        if len(normalized_paths) == 1:
            self.send_json(
                HTTPStatus.OK,
                {
                    "code": 0,
                    "message": "file deleted",
                    "data": deleted_items[0],
                },
            )
            self.write_audit_log(
                action_type="delete_file",
                indexed_name=str(deleted_items[0].get("indexedName", "")),
                file_path=str(deleted_items[0].get("path", "")),
            )
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "batch delete completed",
                "data": {
                    "requested": len(normalized_paths),
                    "deletedCount": len(deleted_items),
                    "notFoundCount": len(missing_items),
                    "deleted": deleted_items,
                    "notFound": missing_items,
                },
            },
        )
        for deleted_item in deleted_items:
            self.write_audit_log(
                action_type="delete_file",
                indexed_name=str(deleted_item.get("indexedName", "")),
                file_path=str(deleted_item.get("path", "")),
                extra={"batch": True},
            )

    def handle_rename_file(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        relative_path = payload.get("path")
        indexed_name = payload.get("indexedName")
        if not isinstance(relative_path, str) or not relative_path:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40017, "missing file path")
            return
        if not isinstance(indexed_name, str):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40018, "missing indexed name")
            return

        normalized_name = sanitize_index_name(indexed_name)
        if normalized_name is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40019, "invalid indexed name")
            return

        resolved = resolve_relative_path(relative_path)
        if resolved is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        storage_type, target_path, normalized_path = resolved
        if not target_path.exists() or not target_path.is_file():
            remove_file_index_record(storage_type, normalized_path)
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        existing_record = get_file_index_record(storage_type, normalized_path)
        if existing_record is None:
            upsert_file_index_record(
                storage_type=storage_type,
                relative_path=normalized_path,
                system_name=target_path.name,
                indexed_name=normalized_name,
                file_size=target_path.stat().st_size,
                mime_type=mimetypes.guess_type(target_path.name)[0] or "application/octet-stream",
            )
        else:
            rename_file_index_record(storage_type, normalized_path, normalized_name)

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "file renamed",
                "data": {
                    "path": normalized_path,
                    "indexedName": normalized_name,
                    "storage": storage_type,
                },
            },
        )
        self.write_audit_log(
            action_type="rename_file",
            indexed_name=normalized_name,
            file_path=normalized_path,
        )

    def handle_move_file(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        relative_path = payload.get("path")
        target_storage = payload.get("targetStorage")
        if not isinstance(relative_path, str) or not relative_path:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40017, "missing file path")
            return

        if not isinstance(target_storage, str) or target_storage not in ("temporary", "permanent"):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40023, "invalid target storage")
            return

        moved, result = move_file_by_relative_path(relative_path, target_storage)
        if not moved:
            if result.get("reason") == "invalid target storage":
                self.send_error_json(HTTPStatus.BAD_REQUEST, 40023, "invalid target storage")
                return
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "file moved",
                "data": result,
            },
        )
        self.write_audit_log(
            action_type="move_file",
            indexed_name=str(result.get("indexedName", "")),
            file_path=str(result.get("path", "")),
            extra={
                "sourceStorage": result.get("sourceStorage", ""),
                "targetStorage": result.get("targetStorage", ""),
            },
        )

    def serve_file(self, request_path: str) -> None:
        resolved = resolve_relative_path(request_path)
        if resolved is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        storage_type, target_path, normalized_path = resolved
        if not target_path.exists() or not target_path.is_file():
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        mime_type = mimetypes.guess_type(target_path.name)[0] or "application/octet-stream"
        record = get_file_index_record(storage_type, normalized_path) or {}
        indexed_name = str(record.get("indexedName") or target_path.name)
        folder_id = normalize_folder_id(record.get("folderId"))
        if not folder_allows_direct_download(folder_id):
            token_value = self.get_query_value(state.DOWNLOAD_TOKEN_QUERY_PARAM) or ""
            if not validate_download_token(token_value, normalized_path):
                self.send_error_json(HTTPStatus.UNAUTHORIZED, 40106, "invalid download token")
                return
        download_name = sanitize_index_name(indexed_name) or target_path.name
        disposition_mode = "inline" if is_inline_mime_type(mime_type) else "attachment"

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(target_path.stat().st_size))
        self.send_header("Content-Disposition", build_content_disposition(disposition_mode, download_name))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

        with target_path.open("rb") as source_file:
            shutil.copyfileobj(source_file, self.wfile, state.UPLOAD_CHUNK_SIZE)

        self.write_audit_log(
            action_type="download_file",
            indexed_name=indexed_name,
            file_path=normalized_path,
        )