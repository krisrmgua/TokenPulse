"""Install TokenPulse.app and keep the existing login-start choice."""
from pathlib import Path
import os, plistlib, re, shutil, signal, subprocess, tempfile

home = Path.home()
source = Path(__file__).resolve().parent
repo = source.parent
name, identity = "TokenPulse", "com.kris.tokenpulse"
domain = f"gui/{os.getuid()}"
agents = home / "Library/LaunchAgents"
plist = agents / f"{identity}.plist"
app = home / f"Applications/{name}.app"
backup = Path(tempfile.mkdtemp(prefix="tokenpulse-install-backup-"))
(home / "Library/Logs").mkdir(parents=True, exist_ok=True)

def run(*args, check=False):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True, text=True)

disabled = run("launchctl", "print-disabled", domain).stdout
autostart = plist.exists() and not re.search(
    re.escape('"' + identity + '"') + r"\s*=>\s*(true|disabled)", disabled)
if app.exists():
    run("ditto", "-c", "-k", "--keepParent", app, backup / f"{app.stem}.zip", check=True)
if plist.exists():
    shutil.copy2(plist, backup / plist.name)
run("launchctl", "bootout", f"{domain}/{identity}")
pattern = "^" + re.escape(str(app / "Contents/MacOS" / name)) + r"([[:space:]]|$)"
found = run("pgrep", "-f", pattern)
for value in found.stdout.split():
    try:
        os.kill(int(value), signal.SIGTERM)
    except ProcessLookupError:
        pass
app.parent.mkdir(parents=True, exist_ok=True)
if app.exists():
    shutil.rmtree(app)
run("ditto", source / "TokenPulse.app", app, check=True)
run("codesign", "--verify", "--deep", "--strict", app, check=True)
register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
run(register, "-u", source / "TokenPulse.app")
run(register, "-f", app, check=True)
agents.mkdir(parents=True, exist_ok=True)
with plist.open("wb") as file:
    plistlib.dump({
        "Label": identity,
        "ProgramArguments": [str(app / "Contents/MacOS/TokenPulse")],
        "RunAtLoad": True,
        "KeepAlive": False,
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": str(home / "Library/Logs/tokenpulse.out.log"),
        "StandardErrorPath": str(home / "Library/Logs/tokenpulse.err.log"),
    }, file)
bin_dir = home / "bin"
bin_dir.mkdir(exist_ok=True)
cli = bin_dir / "tokenpulse"
repo_cli = repo / "bin/tokenpulse"
if cli.is_symlink() or not cli.exists():
    if cli.is_symlink() or cli.exists():
        cli.unlink()
    cli.symlink_to(repo_cli)
os.chmod(repo_cli, 0o755)
if autostart or not (backup / plist.name).exists():
    run("launchctl", "enable", f"{domain}/{identity}")
    run("launchctl", "bootstrap", domain, plist, check=True)
    started = "enabled"
else:
    run("launchctl", "disable", f"{domain}/{identity}")
    run("open", app, check=True)
    started = "disabled"
print(f"Installed {app}; login start {started} (preserved when a previous agent existed). Backup: {backup}")
