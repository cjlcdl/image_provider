import cgi
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional
from urllib.parse import parse_qs, urlsplit

import server_state as state
from config import CLEANUP_HOUR, DOWNLOAD_TOKEN_MAX_DAYS, FILE_ROUTE_PREFIX, HOST, PERMANENT_TOKEN_HEADER, PORT
from folder_index import folder_requires_password, get_disk_capacity, get_folder
from server_auth import (
    is_permanent_token_verification_available,
    validate_folder_password_token,
    validate_folder_passwords_token,
    validate_permanent_token,
)
from server_handlers_files import FileManagementHandlerMixin
from server_handlers_folders import FolderManagementHandlerMixin
from server_handlers_upload import UploadHandlerMixin
from server_storage import append_audit_log
from server_utils import build_audit_log_line, normalize_folder_id, now_local


def create_server() -> ThreadingHTTPServer:
    try:
        return ThreadingHTTPServer((HOST, PORT), StorageProviderHandler)
    except OSError as exc:
        if HOST == "0.0.0.0":
            raise
        print("server bind failed on {}:{}: {}; fallback to 0.0.0.0:{}".format(HOST, PORT, exc, PORT))
        return ThreadingHTTPServer(("0.0.0.0", PORT), StorageProviderHandler)


class BaseStorageProviderHandler(BaseHTTPRequestHandler):
    server_version = "ImageProvider/2.0"

    def do_GET(self) -> None:
        self.execute_safely(self._do_get)

    def do_POST(self) -> None:
        self.execute_safely(self._do_post)

    def do_PUT(self) -> None:
        self.execute_safely(lambda: self.send_error_json(HTTPStatus.METHOD_NOT_ALLOWED, 40500, "method not allowed"))

    def do_DELETE(self) -> None:
        self.execute_safely(self._do_delete)

    def do_PATCH(self) -> None:
        self.execute_safely(self._do_patch)

    def log_message(self, format: str, *args: Any) -> None:
        print("[{}] {} {}".format(self.log_date_time_string(), self.address_string(), format % args))

    def execute_safely(self, operation: Any) -> None:
        try:
            operation()
        except BrokenPipeError:
            self.close_connection = True
        except ConnectionResetError:
            self.close_connection = True
        except Exception as exc:
            print("request handling failed: {}".format(exc))
            self.try_send_internal_error()

    def try_send_internal_error(self) -> None:
        if getattr(self, "wfile", None) is None:
            return
        if self.wfile.closed:
            return
        try:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, 50000, "internal server error")
        except Exception:
            self.close_connection = True

    def request_path(self) -> str:
        return urlsplit(self.path).path

    def request_query(self) -> Dict[str, list]:
        return parse_qs(urlsplit(self.path).query, keep_blank_values=True)

    def get_query_value(self, key: str) -> Optional[str]:
        values = self.request_query().get(key, [])
        if not values:
            return None
        value = values[0].strip()
        return value or None

    def parse_positive_int_query(self, key: str, default: int, error_code: int, error_message: str) -> Optional[int]:
        raw_value = self.get_query_value(key)
        if raw_value is None:
            return default

        try:
            parsed_value = int(raw_value)
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, error_code, error_message)
            return None

        if parsed_value <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, error_code, error_message)
            return None

        return parsed_value

    def request_app_channel(self) -> str:
        return self.headers.get(state.APP_CHANNEL_HEADER, "").strip()

    def request_user(self) -> str:
        return self.headers.get(state.USER_HEADER, "").strip()

    def require_folder_password(
        self,
        folder_id: Optional[str],
        header_name: str = state.FOLDER_PASSWORD_TOKEN_HEADER,
    ) -> Optional[str]:
        normalized_folder_id = normalize_folder_id(folder_id)
        if not normalized_folder_id:
            return None

        folder_record = get_folder(normalized_folder_id)
        if folder_record is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return None
        if not folder_requires_password(folder_record):
            return None

        token_value = self.headers.get(header_name, "").strip()
        if not token_value:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, 40105, "missing folder password token")
            return None

        is_valid, password, code, message = validate_folder_password_token(token_value, normalized_folder_id)
        if not is_valid:
            status = HTTPStatus.UNAUTHORIZED if code < 50000 else HTTPStatus.INTERNAL_SERVER_ERROR
            if code == 40302:
                status = HTTPStatus.FORBIDDEN
            if code == 40403:
                status = HTTPStatus.NOT_FOUND
            self.send_error_json(status, code, message)
            return None
        return password

    def require_folder_passwords(
        self,
        folder_ids: list,
        header_name: str = state.FOLDER_PASSWORDS_TOKEN_HEADER,
    ) -> Optional[Dict[str, str]]:
        normalized_folder_ids = []
        for folder_id in folder_ids:
            normalized_folder_id = normalize_folder_id(folder_id)
            if normalized_folder_id:
                normalized_folder_ids.append(normalized_folder_id)

        if not normalized_folder_ids:
            return {}

        token_value = self.headers.get(header_name, "").strip()
        if not token_value:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, 40107, "missing folder passwords token")
            return None

        is_valid, passwords, code, message = validate_folder_passwords_token(
            token_value,
            normalized_folder_ids,
        )
        if not is_valid:
            status = HTTPStatus.UNAUTHORIZED if code < 50000 else HTTPStatus.INTERNAL_SERVER_ERROR
            if code == 40302:
                status = HTTPStatus.FORBIDDEN
            if code == 40403:
                status = HTTPStatus.NOT_FOUND
            self.send_error_json(status, code, message)
            return None
        return passwords or {}

    def write_audit_log(
        self,
        *,
        action_type: str,
        indexed_name: str = "",
        file_path: str = "",
        extra: Optional[Dict[str, Any]] = None,
    ) -> None:
        append_audit_log(
            "audit {}".format(
                build_audit_log_line(
                    action_type=action_type,
                    user=self.request_user(),
                    app_channel=self.request_app_channel(),
                    indexed_name=indexed_name,
                    file_path=file_path,
                    client_ip=self.client_address[0],
                    extra=extra,
                )
            )
        )

    def send_json(self, status: HTTPStatus, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: HTTPStatus, code: int, message: str) -> None:
        self.send_json(status, {"code": code, "message": message, "data": None})

    def authorize_management_request(self) -> bool:
        token_value = self.headers.get(PERMANENT_TOKEN_HEADER, "").strip()
        if not token_value:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, 40103, "missing management token")
            return False

        is_valid, _token_payload, code, message = validate_permanent_token(token_value)
        if not is_valid:
            status = HTTPStatus.UNAUTHORIZED if code < 50000 else HTTPStatus.INTERNAL_SERVER_ERROR
            self.send_error_json(status, code, message)
            return False

        return True

    def read_json_body(self) -> Optional[Dict[str, Any]]:
        content_type = self.headers.get("Content-Type", "")
        media_type, _ = cgi.parse_header(content_type)
        if media_type != "application/json":
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40014, "content type must be application/json")
            return None

        content_length = self.headers.get("Content-Length")
        if not content_length:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40001, "missing content length")
            return None

        try:
            content_length_value = int(content_length)
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return None

        if content_length_value <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40005, "invalid content length")
            return None

        if content_length_value > state.MAX_JSON_BODY_BYTES:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40015, "json body too large")
            return None

        raw_body = self.rfile.read(content_length_value)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40016, "invalid json body")
            return None

        if not isinstance(payload, dict):
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40016, "invalid json body")
            return None

        return payload

    def _do_get(self) -> None:
        request_path = self.request_path()
        if request_path == "/api/health":
            disk_capacity = get_disk_capacity()
            self.send_json(
                HTTPStatus.OK,
                {
                    "code": 0,
                    "message": "ok",
                    "data": {
                        "status": "running",
                        "serverTime": now_local().isoformat(),
                        "cleanupHour": CLEANUP_HOUR,
                        "tokenHeader": PERMANENT_TOKEN_HEADER,
                        "managementTokenReady": is_permanent_token_verification_available(),
                        "downloadTokenMaxDays": DOWNLOAD_TOKEN_MAX_DAYS,
                        **disk_capacity,
                    },
                },
            )
            return

        if request_path == "/api/folders":
            self.handle_list_folders()
            return

        if request_path == "/api/files":
            self.handle_list_files()
            return

        upload_id, upload_action = self.parse_resumable_upload_path(request_path)
        if upload_action == "session" and upload_id is not None:
            self.handle_resumable_upload_status(upload_id)
            return

        if request_path.startswith("{}/".format(FILE_ROUTE_PREFIX)):
            self.serve_file(request_path)
            return

        self.send_error_json(HTTPStatus.NOT_FOUND, 40400, "resource not found")

    def _do_post(self) -> None:
        request_path = self.request_path()
        if request_path == "/api/upload":
            self.handle_upload()
            return

        if request_path == "/api/upload/resumable/init":
            self.handle_resumable_upload_init()
            return

        if request_path == "/api/files/move":
            self.handle_move_file()
            return

        if request_path == "/api/files/folder":
            self.handle_assign_files_to_folder()
            return

        if request_path == "/api/folders":
            self.handle_create_folder()
            return

        if request_path == "/api/folders/download-link":
            self.handle_create_download_link()
            return

        if request_path == "/api/folders/archive":
            self.handle_download_folder_archive()
            return

        upload_id, upload_action = self.parse_resumable_upload_path(request_path)
        if upload_action == "complete" and upload_id is not None:
            self.handle_resumable_upload_complete(upload_id)
            return

        self.send_error_json(HTTPStatus.NOT_FOUND, 40400, "resource not found")

    def _do_delete(self) -> None:
        request_path = self.request_path()
        upload_id, upload_action = self.parse_resumable_upload_path(request_path)
        if upload_action == "session" and upload_id is not None:
            self.handle_resumable_upload_cancel(upload_id)
            return

        if request_path == "/api/folders":
            self.handle_delete_folder()
            return

        if self.request_path() != "/api/files":
            self.send_error_json(HTTPStatus.NOT_FOUND, 40400, "resource not found")
            return

        self.handle_delete_file()

    def _do_patch(self) -> None:
        request_path = self.request_path()
        upload_id, upload_action = self.parse_resumable_upload_path(request_path)
        if upload_action == "session" and upload_id is not None:
            self.handle_resumable_upload_chunk(upload_id)
            return

        if request_path == "/api/folders":
            self.handle_update_folder()
            return

        if self.request_path() != "/api/files":
            self.send_error_json(HTTPStatus.NOT_FOUND, 40400, "resource not found")
            return

        self.handle_rename_file()


class StorageProviderHandler(
    UploadHandlerMixin,
    FileManagementHandlerMixin,
    FolderManagementHandlerMixin,
    BaseStorageProviderHandler,
):
    pass