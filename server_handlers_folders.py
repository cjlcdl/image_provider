import mimetypes
import shutil
import tempfile
import zipfile
from http import HTTPStatus
from pathlib import Path, PurePosixPath
from urllib.parse import quote

import server_state as state
from folder_index import (
    build_folder_name_chain,
    change_folder_password,
    collect_descendant_folder_ids,
    create_download_token,
    create_folder,
    delete_folder_recursive,
    export_folder_record,
    folder_requires_password,
    get_disk_capacity,
    get_folder,
    list_folders,
    sanitize_folder_name,
    update_folder,
)
from server_storage import (
    delete_file_by_relative_path,
    get_file_index_record,
    list_all_files,
    remove_file_index_record,
    resolve_relative_path,
    set_file_index_folder,
    upsert_file_index_record,
)
from server_utils import folder_allows_direct_download, normalize_folder_id
from server_utils import build_content_disposition, sanitize_index_name


class FolderManagementHandlerMixin:
    def _build_archive_relative_folder_path(self, root_folder_id: str, folder_id: str) -> str:
        root_chain = build_folder_name_chain(root_folder_id)
        folder_chain = build_folder_name_chain(folder_id)
        if not root_chain or not folder_chain:
            return "archive"
        relative_parts = folder_chain[len(root_chain) :]
        return str(PurePosixPath(root_chain[-1], *relative_parts))

    def _build_unique_archive_path(self, used_paths: set, directory_path: str, file_name: str) -> str:
        safe_name = sanitize_index_name(file_name) or "download"
        candidate_path = str(PurePosixPath(directory_path, safe_name))
        if candidate_path not in used_paths:
            used_paths.add(candidate_path)
            return candidate_path

        file_path = PurePosixPath(safe_name)
        base_name = file_path.stem or "download"
        extension = file_path.suffix
        index = 1
        while True:
            candidate_name = "{} ({}){}".format(base_name, index, extension)
            candidate_path = str(PurePosixPath(directory_path, candidate_name))
            if candidate_path not in used_paths:
                used_paths.add(candidate_path)
                return candidate_path
            index += 1

    def handle_list_folders(self) -> None:
        if not self.authorize_management_request():
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "ok",
                "data": {
                    "folders": list_folders(),
                    **get_disk_capacity(),
                },
            },
        )

    def handle_create_folder(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        name = payload.get("name")
        parent_id = normalize_folder_id(payload.get("parentId"))
        encrypted = payload.get("encrypted") is True
        allow_direct_download = payload.get("allowDirectDownload") is True
        password = payload.get("password") if isinstance(payload.get("password"), str) else None

        if not isinstance(name, str) or sanitize_folder_name(name) is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40029, "invalid folder name")
            return

        if parent_id:
            parent_record = get_folder(parent_id)
            if parent_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                return
            if folder_requires_password(parent_record):
                if self.require_folder_password(parent_id, state.TARGET_FOLDER_PASSWORD_TOKEN_HEADER) is None:
                    return

        try:
            result = create_folder(
                name=name,
                parent_id=parent_id,
                encrypted=encrypted,
                password=password,
                allow_direct_download=allow_direct_download,
            )
        except PermissionError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40030, "missing folder password")
            return
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40029, "invalid folder name")
            return
        except KeyError:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "folder created",
                "data": result,
            },
        )
        self.write_audit_log(
            action_type="create_folder",
            indexed_name=str(result.get("name", "")),
            file_path=str(result.get("path", "")),
            extra={
                "resourceType": "folder",
                "folderId": result.get("id"),
                "parentId": result.get("parentId"),
                "encrypted": result.get("encrypted"),
                "allowDirectDownload": result.get("allowDirectDownload"),
            },
        )

    def handle_update_folder(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        folder_id = normalize_folder_id(payload.get("folderId"))
        if not folder_id:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40031, "missing folder id")
            return

        current_record = get_folder(folder_id)
        if current_record is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return
        previous_record = export_folder_record(current_record)

        if folder_requires_password(current_record):
            if self.require_folder_password(folder_id) is None:
                return

        name = payload.get("name") if isinstance(payload.get("name"), str) else None
        parent_provided = "parentId" in payload
        parent_id = normalize_folder_id(payload.get("parentId")) if parent_provided else None
        encrypted_provided = isinstance(payload.get("encrypted"), bool)
        encrypted = payload.get("encrypted") if encrypted_provided else None
        allow_direct_download = (
            payload.get("allowDirectDownload")
            if isinstance(payload.get("allowDirectDownload"), bool)
            else None
        )
        new_password = payload.get("newPassword") if isinstance(payload.get("newPassword"), str) else None

        if parent_provided and parent_id:
            target_parent_record = get_folder(parent_id)
            if target_parent_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                return
            if folder_requires_password(target_parent_record):
                if self.require_folder_password(parent_id, state.TARGET_FOLDER_PASSWORD_TOKEN_HEADER) is None:
                    return

        try:
            if encrypted_provided and current_record.get("encrypted") != encrypted:
                result = update_folder(
                    folder_id,
                    name=name,
                    parent_id=parent_id if parent_provided else None,
                    parent_id_provided=parent_provided,
                    encrypted=encrypted,
                    allow_direct_download=allow_direct_download,
                    password=new_password,
                )
            else:
                result = update_folder(
                    folder_id,
                    name=name,
                    parent_id=parent_id if parent_provided else None,
                    parent_id_provided=parent_provided,
                    allow_direct_download=allow_direct_download,
                )
                if new_password and bool(current_record.get("encrypted")):
                    result = change_folder_password(folder_id, new_password)
        except PermissionError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40030, "missing folder password")
            return
        except ValueError as error:
            message = str(error)
            if message == "invalid target parent":
                self.send_error_json(HTTPStatus.BAD_REQUEST, 40032, "invalid target parent")
                return
            if message == "folder is not encrypted":
                self.send_error_json(HTTPStatus.BAD_REQUEST, 40033, "folder is not encrypted")
                return
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40029, "invalid folder name")
            return
        except KeyError:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "folder updated",
                "data": result,
            },
        )
        log_extra = {
            "resourceType": "folder",
            "folderId": result.get("id"),
            "oldName": previous_record.get("name"),
            "newName": result.get("name"),
            "oldPath": previous_record.get("path"),
            "newPath": result.get("path"),
            "oldParentId": previous_record.get("parentId"),
            "newParentId": result.get("parentId"),
            "oldEncrypted": previous_record.get("encrypted"),
            "newEncrypted": result.get("encrypted"),
            "oldAllowDirectDownload": previous_record.get("allowDirectDownload"),
            "newAllowDirectDownload": result.get("allowDirectDownload"),
            "passwordChanged": bool(new_password),
        }
        renamed = previous_record.get("name") != result.get("name")
        moved = previous_record.get("parentId") != result.get("parentId")
        protection_changed = (
            previous_record.get("encrypted") != result.get("encrypted")
            or previous_record.get("allowDirectDownload") != result.get("allowDirectDownload")
            or bool(new_password)
        )
        if renamed:
            self.write_audit_log(
                action_type="rename_folder",
                indexed_name=str(result.get("name", "")),
                file_path=str(result.get("path", "")),
                extra=log_extra,
            )
        if moved:
            self.write_audit_log(
                action_type="move_folder",
                indexed_name=str(result.get("name", "")),
                file_path=str(result.get("path", "")),
                extra=log_extra,
            )
        if (not renamed and not moved) or protection_changed:
            self.write_audit_log(
                action_type="update_folder",
                indexed_name=str(result.get("name", "")),
                file_path=str(result.get("path", "")),
                extra=log_extra,
            )

    def handle_delete_folder(self) -> None:
        if not self.authorize_management_request():
            return

        folder_id = normalize_folder_id(self.get_query_value("folderId"))
        if not folder_id:
            payload = None
            content_length = self.headers.get("Content-Length", "").strip()
            if content_length and content_length != "0":
                payload = self.read_json_body()
            folder_id = normalize_folder_id(payload.get("folderId")) if payload else None
        if not folder_id:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40031, "missing folder id")
            return

        folder_record = get_folder(folder_id)
        if folder_record is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return
        deleted_folder_records = [export_folder_record(folder_record)]
        for descendant_folder_id in collect_descendant_folder_ids(folder_id):
            descendant_record = get_folder(descendant_folder_id)
            if descendant_record is not None:
                deleted_folder_records.append(export_folder_record(descendant_record))

        if folder_requires_password(folder_record):
            if self.require_folder_password(folder_id) is None:
                return

        related_folder_ids = [folder_id] + collect_descendant_folder_ids(folder_id)
        related_folder_id_set = set(related_folder_ids)
        deleted_files = []
        for file_item in list_all_files():
            if file_item.get("folderId") not in related_folder_id_set:
                continue
            deleted, result = delete_file_by_relative_path(str(file_item.get("path", "")))
            if deleted:
                deleted_files.append(result)

        try:
            removed_folder_ids = delete_folder_recursive(folder_id)
        except KeyError:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "folder deleted",
                "data": {
                    "folderId": folder_id,
                    "deletedFolderCount": len(removed_folder_ids),
                    "deletedFileCount": len(deleted_files),
                    "deletedFolders": removed_folder_ids,
                },
            },
        )
        for deleted_file in deleted_files:
            self.write_audit_log(
                action_type="delete_file",
                indexed_name=str(deleted_file.get("indexedName", "")),
                file_path=str(deleted_file.get("path", "")),
                extra={
                    "resourceType": "file",
                    "viaFolderDelete": True,
                    "rootFolderId": folder_id,
                },
            )
        for deleted_folder_record in deleted_folder_records:
            self.write_audit_log(
                action_type="delete_folder",
                indexed_name=str(deleted_folder_record.get("name", "")),
                file_path=str(deleted_folder_record.get("path", "")),
                extra={
                    "resourceType": "folder",
                    "folderId": deleted_folder_record.get("id"),
                    "parentId": deleted_folder_record.get("parentId"),
                    "encrypted": deleted_folder_record.get("encrypted"),
                    "cascade": deleted_folder_record.get("id") != folder_id,
                    "rootFolderId": folder_id,
                    "deletedFolderCount": len(removed_folder_ids),
                    "deletedFileCount": len(deleted_files),
                },
            )

    def handle_assign_files_to_folder(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        target_folder_id = normalize_folder_id(payload.get("folderId"))
        if target_folder_id:
            folder_record = get_folder(target_folder_id)
            if folder_record is None:
                self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
                return
            if folder_requires_password(folder_record):
                if self.require_folder_password(target_folder_id, state.TARGET_FOLDER_PASSWORD_TOKEN_HEADER) is None:
                    return

        relative_paths = []
        if isinstance(payload.get("path"), str) and payload.get("path"):
            relative_paths = [payload["path"]]
        elif isinstance(payload.get("paths"), list):
            relative_paths = [item for item in payload["paths"] if isinstance(item, str) and item]

        if not relative_paths:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40017, "missing file path")
            return

        updated_items = []
        missing_items = []
        for relative_path in relative_paths:
            resolved = resolve_relative_path(relative_path)
            if resolved is None:
                missing_items.append(relative_path)
                continue
            storage_type, target_path, normalized_path = resolved
            if not target_path.exists() or not target_path.is_file():
                remove_file_index_record(storage_type, normalized_path)
                missing_items.append(normalized_path)
                continue

            existing_record = get_file_index_record(storage_type, normalized_path)
            previous_folder_id = normalize_folder_id((existing_record or {}).get("folderId"))
            if existing_record is None:
                existing_record = upsert_file_index_record(
                    storage_type=storage_type,
                    relative_path=normalized_path,
                    system_name=target_path.name,
                    indexed_name=target_path.name,
                    file_size=target_path.stat().st_size,
                    mime_type=mimetypes.guess_type(target_path.name)[0] or "application/octet-stream",
                    folder_id=target_folder_id,
                )
            else:
                existing_record = set_file_index_folder(storage_type, normalized_path, target_folder_id)

            updated_items.append(
                {
                    "path": normalized_path,
                    "sourceFolderId": previous_folder_id,
                    "folderId": target_folder_id,
                    "indexedName": str((existing_record or {}).get("indexedName", target_path.name)),
                }
            )

        if not updated_items:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40401, "file not found")
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "file folder updated",
                "data": {
                    "updated": updated_items,
                    "missing": missing_items,
                },
            },
        )
        for updated_item in updated_items:
            self.write_audit_log(
                action_type="move_file_to_folder",
                indexed_name=str(updated_item.get("indexedName", "")),
                file_path=str(updated_item.get("path", "")),
                extra={
                    "resourceType": "file",
                    "sourceFolderId": updated_item.get("sourceFolderId"),
                    "targetFolderId": updated_item.get("folderId"),
                    "batch": len(updated_items) > 1,
                },
            )

    def handle_create_download_link(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        relative_path = payload.get("path")
        expires_in_days = payload.get("expiresInDays")
        if not isinstance(relative_path, str) or not relative_path:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40017, "missing file path")
            return
        if isinstance(expires_in_days, str) and expires_in_days.isdigit():
            expires_in_days = int(expires_in_days)
        if not isinstance(expires_in_days, int) or expires_in_days <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40034, "invalid download link days")
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

        record = get_file_index_record(storage_type, normalized_path) or {}
        folder_id = normalize_folder_id(record.get("folderId"))
        if not folder_allows_direct_download(folder_id):
            if self.require_folder_password(folder_id) is None:
                return
            download_link = create_download_token(normalized_path, folder_id or "", expires_in_days)
            url = "{}?{}={}".format(
                normalized_path,
                state.DOWNLOAD_TOKEN_QUERY_PARAM,
                quote(download_link["token"]),
            )
            self.send_json(
                HTTPStatus.OK,
                {
                    "code": 0,
                    "message": "download link created",
                    "data": {
                        "path": normalized_path,
                        "url": url,
                        "expiresAt": download_link["expiresAt"],
                        "expiresInDays": download_link["expiresInDays"],
                        "passwordExempt": False,
                    },
                },
            )
            return

        self.send_json(
            HTTPStatus.OK,
            {
                "code": 0,
                "message": "download link created",
                "data": {
                    "path": normalized_path,
                    "url": normalized_path,
                    "expiresAt": None,
                    "expiresInDays": None,
                    "passwordExempt": True,
                },
            },
        )

    def handle_download_folder_archive(self) -> None:
        if not self.authorize_management_request():
            return

        payload = self.read_json_body()
        if payload is None:
            return

        folder_id = normalize_folder_id(payload.get("folderId"))
        if not folder_id:
            self.send_error_json(HTTPStatus.BAD_REQUEST, 40031, "missing folder id")
            return

        folder_record = get_folder(folder_id)
        if folder_record is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, 40403, "folder not found")
            return

        descendant_folder_ids = collect_descendant_folder_ids(folder_id)
        related_folder_ids = [folder_id, *descendant_folder_ids]
        encrypted_folder_ids = []
        for related_folder_id in related_folder_ids:
            related_record = get_folder(related_folder_id)
            if folder_requires_password(related_record):
                encrypted_folder_ids.append(related_folder_id)

        if encrypted_folder_ids:
            passwords = self.require_folder_passwords(encrypted_folder_ids)
            if passwords is None:
                return

        archive_name = "{}.zip".format(sanitize_index_name(str(folder_record.get("name", "archive"))) or "archive")
        folder_id_set = set(related_folder_ids)
        folder_paths = {
            related_folder_id: self._build_archive_relative_folder_path(folder_id, related_folder_id)
            for related_folder_id in related_folder_ids
        }

        file_count = 0
        archive_temp = tempfile.NamedTemporaryFile(delete=False, suffix=".zip")
        archive_temp_path = archive_temp.name
        archive_temp.close()

        try:
            used_archive_paths = set()
            with zipfile.ZipFile(
                archive_temp_path,
                mode="w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=6,
            ) as archive_file:
                for related_folder_id in related_folder_ids:
                    folder_path = folder_paths.get(related_folder_id)
                    if folder_path:
                        archive_file.writestr("{}/".format(folder_path.rstrip("/")), "")

                for file_item in list_all_files():
                    item_folder_id = normalize_folder_id(file_item.get("folderId"))
                    if item_folder_id not in folder_id_set:
                        continue

                    relative_path = str(file_item.get("path", ""))
                    resolved = resolve_relative_path(relative_path)
                    if resolved is None:
                        continue

                    storage_type, target_path, normalized_path = resolved
                    if not target_path.exists() or not target_path.is_file():
                        remove_file_index_record(storage_type, normalized_path)
                        continue

                    archive_directory = folder_paths.get(item_folder_id)
                    if not archive_directory:
                        continue

                    indexed_name = str(file_item.get("indexedName") or target_path.name)
                    archive_entry_path = self._build_unique_archive_path(
                        used_archive_paths,
                        archive_directory,
                        indexed_name,
                    )
                    archive_file.write(target_path, arcname=archive_entry_path)
                    file_count += 1

            final_archive_path = Path(archive_temp_path)

            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(final_archive_path.stat().st_size))
            self.send_header("Content-Disposition", build_content_disposition("attachment", archive_name))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()

            with final_archive_path.open("rb") as archive_stream:
                shutil.copyfileobj(archive_stream, self.wfile, state.UPLOAD_CHUNK_SIZE)

            self.write_audit_log(
                action_type="download_folder_archive",
                indexed_name=str(folder_record.get("name", "")),
                file_path=str(folder_paths.get(folder_id, "/")),
                extra={
                    "resourceType": "folder",
                    "folderId": folder_id,
                    "archiveName": archive_name,
                    "folderCount": len(related_folder_ids),
                    "fileCount": file_count,
                },
            )
        finally:
            temp_archive_path = Path(archive_temp_path)
            temp_archive_path.unlink(missing_ok=True)