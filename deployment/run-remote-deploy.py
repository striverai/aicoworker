#!/usr/bin/env python3
import os
import shlex
import sys
import time
from pathlib import Path

import paramiko


HOST = os.environ.get("AICOWORKER_VPS_HOST", "147.93.159.110")
USER = os.environ.get("AICOWORKER_VPS_USER", "root")
PASSWORD = os.environ.get("AICOWORKER_VPS_PASSWORD")
DOMAIN = os.environ.get("DOMAIN", "ai.globalpharma.vn")
SKIP_INSTALL = os.environ.get("SKIP_INSTALL")
LOCAL_SCRIPT = Path(__file__).with_name("deploy-ai-globalpharma.sh")
REMOTE_SCRIPT = "/tmp/deploy-ai-globalpharma.sh"


def main() -> int:
    if not PASSWORD:
        print("Missing AICOWORKER_VPS_PASSWORD.", file=sys.stderr)
        return 1
    if not LOCAL_SCRIPT.exists():
        print(f"Deploy script not found: {LOCAL_SCRIPT}", file=sys.stderr)
        return 1

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(
        hostname=HOST,
        username=USER,
        password=PASSWORD,
        timeout=20,
        banner_timeout=20,
        auth_timeout=20,
    )

    with ssh.open_sftp() as sftp:
        sftp.put(str(LOCAL_SCRIPT), REMOTE_SCRIPT)
        sftp.chmod(REMOTE_SCRIPT, 0o700)

    env = {"DOMAIN": DOMAIN}
    if SKIP_INSTALL is not None:
        env["SKIP_INSTALL"] = SKIP_INSTALL
    remote_env = " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items())
    command = f"bash -n {REMOTE_SCRIPT} && {remote_env} bash {REMOTE_SCRIPT}"
    channel = ssh.get_transport().open_session()
    channel.get_pty()
    channel.exec_command(command)

    while True:
        while channel.recv_ready():
            sys.stdout.write(channel.recv(8192).decode("utf-8", "replace"))
            sys.stdout.flush()
        while channel.recv_stderr_ready():
            sys.stderr.write(channel.recv_stderr(8192).decode("utf-8", "replace"))
            sys.stderr.flush()
        if channel.exit_status_ready():
            break
        time.sleep(0.2)

    while channel.recv_ready():
        sys.stdout.write(channel.recv(8192).decode("utf-8", "replace"))
        sys.stdout.flush()
    while channel.recv_stderr_ready():
        sys.stderr.write(channel.recv_stderr(8192).decode("utf-8", "replace"))
        sys.stderr.flush()

    status = channel.recv_exit_status()
    ssh.close()
    return status


if __name__ == "__main__":
    raise SystemExit(main())
