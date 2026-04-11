import threading

import server_state as state
from config import PUBLIC_BASE_URL
from folder_index import load_folder_index_state
from server_handler import create_server
from server_storage import cleanup_expired_upload_sessions, cleanup_scheduler, ensure_storage, load_permanent_index


def run() -> None:
    ensure_storage()
    cleanup_expired_upload_sessions()
    load_permanent_index()
    load_folder_index_state()
    cleanup_thread = threading.Thread(target=cleanup_scheduler, daemon=True)
    cleanup_thread.start()

    server = create_server()
    actual_host, actual_port = server.server_address[:2]
    print("Image provider listening on {}:{}".format(actual_host, actual_port))
    if PUBLIC_BASE_URL:
        print("Image provider public base URL {}".format(PUBLIC_BASE_URL))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print("server stopped unexpectedly: {}".format(exc))
    finally:
        state.shutdown_event.set()
        server.server_close()