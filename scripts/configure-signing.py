#!/usr/bin/env python3
"""Save this developer's signing values outside the shared Xcode project."""
import argparse
from hashlib import sha1
import json
from pathlib import Path
import re
import subprocess
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "ios/TaskLens.xcodeproj/project.pbxproj"
LOCAL = "ios/Config/Signing.local.xcconfig"
TEAM_VARIABLE = "$(TASKLENS_DEVELOPMENT_TEAM)"
BUNDLE_VARIABLE = "$(TASKLENS_BUNDLE_IDENTIFIER)"


def ident(name):
    return sha1(name.encode()).hexdigest()[:24].upper()


def configuration(project, target, name):
    key = ident(f"config:{target}:{name}")
    match = re.search(r"\b" + key + r"\s*(?:/\*.*?\*/\s*)?=\s*\{", project)
    if not match:
        raise ValueError(f"Could not find the {target} {name} build configuration.")
    start, depth = match.end() - 1, 0
    # Quoted strings and comments can contain braces; they are not structure.
    tokens = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}]'
    for token in re.finditer(tokens, project[start:]):
        if token.group() == "{":
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return project[start:start + token.end()]
    raise ValueError("The Xcode project has an incomplete build configuration.")


def setting(block, key):
    match = re.search(r"(?m)^\s*" + re.escape(key) + r'\s*=\s*("(?:\\.|[^"\\])*"|[^;\n]+);', block)
    if not match:
        raise ValueError(f"Missing {key} in the Xcode project.")
    value = re.sub(r"/\*.*?\*/", "", match.group(1)).strip()
    return json.loads(value) if value.startswith('"') else value


def validate(team, bundle):
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or team == "YOURTEAMID":
        raise ValueError("Use your 10-character Apple development team ID.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise ValueError("Use a bundle identifier such as dev.yourname.codejam16.tasklens.")
    return team, bundle


def import_values(project):
    values = set()
    for name in ("Debug", "Release"):
        block = configuration(project, "app", name)
        values.add((setting(block, "DEVELOPMENT_TEAM"), setting(block, "PRODUCT_BUNDLE_IDENTIFIER")))
    if len(values) != 1:
        raise ValueError("Debug and Release use different identities. Supply --team and --bundle-id explicitly.")
    return validate(*values.pop())


def save_local(root, team, bundle, replace=False):
    validate(team, bundle)
    path = root / LOCAL
    content = ("// Personal to this checkout. Git ignores this file.\n"
               f"TASKLENS_DEVELOPMENT_TEAM = {team}\n"
               f"TASKLENS_BUNDLE_IDENTIFIER = {bundle}\n")
    if path.exists():
        if path.read_text() == content:
            return False
        if not replace:
            raise ValueError(f"{LOCAL} already exists. Edit it directly, or use --replace-local to back it up and replace it.")
        backup = root / ".build/signing-backups" / (path.name + "." + uuid4().hex[:8])
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_bytes(path.read_bytes())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return True


def check_shared(root):
    project = (root / PROJECT).read_text()
    for name in ("Debug", "Release"):
        for target in ("app", "tests"):
            block = configuration(project, target, name)
            bundle = BUNDLE_VARIABLE + (".tests" if target == "tests" else "")
            if setting(block, "DEVELOPMENT_TEAM") != TEAM_VARIABLE or setting(block, "PRODUCT_BUNDLE_IDENTIFIER") != bundle:
                raise ValueError("Personal signing values are in project.pbxproj. Restore its variable-based settings and edit Signing.local.xcconfig instead.")
        block = configuration(project, "project", name)
        if setting(block, "baseConfigurationReference") != ident("ref:Config/Signing.xcconfig"):
            raise ValueError("The project is not connected to Config/Signing.xcconfig.")
    shared = (root / "ios/Config/Signing.xcconfig").read_text()
    if '#include? "Signing.local.xcconfig"' not in shared:
        raise ValueError("The local signing configuration is not included.")


def show_local(root):
    path = root / LOCAL
    if not path.exists():
        raise ValueError("Local signing is missing. Import your saved commit or supply --team and --bundle-id first.")
    values = {}
    for key in ("TASKLENS_DEVELOPMENT_TEAM", "TASKLENS_BUNDLE_IDENTIFIER"):
        match = re.search(r"(?m)^\s*" + key + r"\s*=\s*([^\r\n]+)", path.read_text())
        if not match:
            raise ValueError(f"Missing {key} in {LOCAL}.")
        values[key] = match.group(1).split("//", 1)[0].strip()
    team, bundle = validate(values["TASKLENS_DEVELOPMENT_TEAM"], values["TASKLENS_BUNDLE_IDENTIFIER"])
    print(f"Configured local team: {team}")
    print(f"Configured local app bundle ID: {bundle}")
    print("Xcode may display $(TASKLENS_BUNDLE_IDENTIFIER); that reference reads the bundle ID above.")


def repair_project(root):
    path = root / PROJECT
    before = path.read_text()
    after = before
    for name in ("Debug", "Release"):
        for target in ("app", "tests"):
            block = configuration(after, target, name)
            updated = block
            bundle = BUNDLE_VARIABLE + (".tests" if target == "tests" else "")
            for key, value in (("DEVELOPMENT_TEAM", TEAM_VARIABLE), ("PRODUCT_BUNDLE_IDENTIFIER", bundle)):
                pattern = r"(?m)^(\s*" + key + r"\s*=\s*)(?:\"(?:\\.|[^\"\\])*\"|[^;\n]+);"
                updated, count = re.subn(pattern, lambda match: match.group(1) + json.dumps(value) + ";", updated)
                if count != 1:
                    raise ValueError(f"Could not safely repair {key} for {target} {name}.")
            after = after.replace(block, updated, 1)
    if after == before:
        check_shared(root)
        return False
    backup = root / ".build/signing-backups" / ("project.pbxproj." + uuid4().hex[:8])
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_text(before)
    path.write_text(after)
    try:
        check_shared(root)
    except (ValueError, OSError):
        path.write_text(before)
        raise
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-commit", help="Import your app signing values from a saved local commit SHA.")
    parser.add_argument("--team", help="Your Apple development team ID.")
    parser.add_argument("--bundle-id", help="Your personal app bundle identifier.")
    parser.add_argument("--check-shared", action="store_true", help="Check that the shared project uses variables, without changing files.")
    parser.add_argument("--show", action="store_true", help="Show actual configured local signing values.")
    parser.add_argument("--repair-project", action="store_true", help="Back up and restore variable-based project signing overrides.")
    parser.add_argument("--replace-local", action="store_true", help="Back up an existing local file before replacing its values.")
    args = parser.parse_args()
    try:
        if args.check_shared:
            if args.from_commit or args.team or args.bundle_id or args.show or args.repair_project or args.replace_local:
                raise ValueError("Use --check-shared by itself.")
            check_shared(ROOT)
            print("Shared project signing uses local configuration variables.")
            return
        if args.show and not (args.from_commit or args.team or args.bundle_id or args.repair_project or args.replace_local):
            show_local(ROOT)
            check_shared(ROOT)
            return
        if args.from_commit:
            if args.team or args.bundle_id or not re.fullmatch(r"[0-9a-fA-F]{7,40}", args.from_commit):
                raise ValueError("Use --from-commit with a commit SHA, or use --team together with --bundle-id.")
            result = subprocess.run(["git", "show", f"{args.from_commit}:{PROJECT}"], cwd=ROOT,
                                    capture_output=True, text=True, check=False)
            if result.returncode:
                raise ValueError("That commit is not available in this checkout. Supply --team and --bundle-id instead.")
            team, bundle = import_values(result.stdout)
        elif args.team and args.bundle_id:
            team, bundle = validate(args.team, args.bundle_id)
        else:
            raise ValueError("Supply --team TEAMID --bundle-id dev.yourname.codejam16.tasklens, or --from-commit YOUR_SAVED_COMMIT.")
        if args.repair_project:
            repair_project(ROOT)
        else:
            check_shared(ROOT)
        created = save_local(ROOT, team, bundle, replace=args.replace_local)
        print(("Saved " if created else "Kept ") + LOCAL + ". Reopen Xcode and build.")
        show_local(ROOT)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Signing setup: {error}\n")


if __name__ == "__main__":
    main()
