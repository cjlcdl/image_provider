import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

APP_CHANNEL = datetime.now().strftime("%y%m%d%H%M")

APP_VERSION = "STORAGER"

BASE_URL = "https://your-domain.com" # 填写为实际服务端地址
SCRIPT_DIR = Path(__file__).resolve().parent
GENERATE_KEY_SCRIPT = SCRIPT_DIR / "generate_public_key_dart.py"

USER = [
    "username1",
    "username2",
]


def resolve_executable(executable_name: str) -> str:
    candidates = [executable_name]
    if os.name == "nt" and not Path(executable_name).suffix:
        candidates = [f"{executable_name}.bat", f"{executable_name}.cmd", executable_name]

    for candidate in candidates:
        resolved = shutil.which(candidate)
        if resolved:
            return resolved

    raise FileNotFoundError(f"Could not find '{executable_name}' in PATH.")


FLUTTER_COMMAND = resolve_executable("flutter")


def run_command(command):
    printable = command if isinstance(command, str) else " ".join(command)
    print(f"Executing: {printable}")
    try:
        subprocess.check_call(command, shell=isinstance(command, str), cwd=SCRIPT_DIR)
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"Error: {e.returncode}")
        sys.exit(1)


def generate_public_key() -> None:
    run_command([sys.executable, str(GENERATE_KEY_SCRIPT)])


def clear_generated_public_key() -> None:
    run_command([sys.executable, str(GENERATE_KEY_SCRIPT), "--clear"])


try:
    generate_public_key()
    for user in USER:
        command = [
            FLUTTER_COMMAND,
            "build",
            "apk",
            "--release",
            f"--dart-define=BASE_URL={BASE_URL}",
            f"--dart-define=APP_CHANNEL={APP_CHANNEL}",
            f"--dart-define=USER={user}",
            "--target-platform",
            "android-arm64",
        ]
        run_command(command)

        app_name = f"{APP_VERSION}_{APP_CHANNEL}_{user}.APK"
        source_path = SCRIPT_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
        target_path = SCRIPT_DIR / app_name

        if source_path.exists():
            shutil.move(source_path, target_path)
        else:
            print(f"Error: {user}")
            sys.exit(1)
finally:
    clear_generated_public_key()