#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library.

Run after adding/removing Swift files; no XcodeGen, CocoaPods, or packages required.
"""
from hashlib import sha1
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
OBJECTS = {}
EXISTING = (IOS / "TaskLens.xcodeproj/project.pbxproj").read_text() if (IOS / "TaskLens.xcodeproj/project.pbxproj").exists() else ""


def ident(name):
    return sha1(name.encode()).hexdigest()[:24].upper()


def add(key_name, isa, **values):
    key = ident(key_name)
    OBJECTS[key] = {"isa": isa, **values}
    return key


def serialize(value, level=0):
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            lines.append("\t" * (level + 1) + f"{serialize(key)} = {serialize(item, level + 1)};")
        lines.append("\t" * level + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        return "(" + ", ".join(serialize(item, level + 1) for item in value) + ("," if value else "") + ")"
    if isinstance(value, int):
        return str(value)
    return value if re.fullmatch(r"[A-Za-z0-9_./]+", value) else json.dumps(value)


def files(folder, target):
    refs, sources, resources = [], [], []
    for file in sorted((IOS / folder).glob("*")):
        if file.suffix not in (".swift", ".plist", ".json"):
            continue
        ref = add(f"ref:{folder}/{file.name}", "PBXFileReference", lastKnownFileType={".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".json": "text.json"}[file.suffix], path=file.name, sourceTree="<group>")
        refs.append(ref)
        if file.suffix == ".swift":
            sources.append(add(f"build:{folder}/{file.name}", "PBXBuildFile", fileRef=ref))
        elif file.suffix == ".json":
            resources.append(add(f"resource:{folder}/{file.name}", "PBXBuildFile", fileRef=ref))
    group = add(f"group:{folder}", "PBXGroup", children=refs, path=folder, sourceTree="<group>")
    phase = add(f"sources:{target}", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
    return group, phase, resources


def configs(name, extra):
    refs = []
    for configuration in ("Debug", "Release"):
        values = dict(extra)
        # Keep local signing settings when adding sources/resources. Debug and
        # Release can intentionally use different teams or bundle identifiers.
        config_id = ident(f"config:{name}:{configuration}")
        match = re.search(r"(?m)^\s*" + config_id + r"(?: /\*.*?\*/)?\s*=\s*\{.*?buildSettings\s*=\s*\{(.*?)\};", EXISTING, re.S)
        if match:
            for key in ("DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER"):
                setting = re.search(r"\b" + key + r"\s*=\s*(.*?);", match.group(1))
                if setting:
                    raw = setting.group(1).strip()
                    values[key] = json.loads(raw) if raw.startswith('"') else raw
        if name == "project":
            values.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O", "ENABLE_TESTABILITY": "YES" if configuration == "Debug" else "NO"})
        refs.append(add(f"config:{name}:{configuration}", "XCBuildConfiguration", buildSettings=values, name=configuration))
    return add(f"configs:{name}", "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def main():
    project, app, tests = ident("project"), ident("target:app"), ident("target:tests")
    app_group, app_sources, app_resources = files("TaskLens", "app")
    test_group, test_sources, test_resources = files("TaskLensTests", "tests")
    app_product = add("product:app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="TaskLens.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("product:tests", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="TaskLensTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("group:products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
    root = add("group:root", "PBXGroup", children=[app_group, test_group, products], sourceTree="<group>")
    phases = {}
    for target in ("app", "tests"):
        resources = app_resources if target == "app" else test_resources
        phases[target] = [add(f"{kind}:{target}", isa, buildActionMask=2147483647, files=resources if kind == "resources" else [], runOnlyForDeploymentPostprocessing=0) for kind, isa in (("frameworks", "PBXFrameworksBuildPhase"), ("resources", "PBXResourcesBuildPhase"))]
    shared = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17", "SWIFT_STRICT_CONCURRENCY": "minimal", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
    target_shared = {"CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_EMIT_LOC_STRINGS": "YES"}
    app_configs = configs("app", {**target_shared, "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "dev.codejam16.tasklens", "INFOPLIST_FILE": "TaskLens/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]})
    test_configs = configs("tests", {**target_shared, "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "dev.codejam16.tasklens.tests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TaskLens.app/TaskLens", "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]})
    proxy = add("proxy:app", "PBXContainerItemProxy", containerPortal=project, proxyType=1, remoteGlobalIDString=app, remoteInfo="TaskLens")
    dependency = add("dependency:app", "PBXTargetDependency", target=app, targetProxy=proxy)
    add("target:app", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[app_sources, *phases["app"]], buildRules=[], dependencies=[], name="TaskLens", productName="TaskLens", productReference=app_product, productType="com.apple.product-type.application")
    add("target:tests", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=[test_sources, *phases["tests"]], buildRules=[], dependencies=[dependency], name="TaskLensTests", productName="TaskLensTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600", "TargetAttributes": {app: {"CreatedOnToolsVersion": "16.0"}, tests: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app}}}, buildConfigurationList=configs("project", shared), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=root, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, tests])
    output = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": OBJECTS, "rootObject": project}
    directory = IOS / "TaskLens.xcodeproj"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(output) + "\n")
    scheme = directory / "xcshareddata/xcschemes/TaskLens.xcscheme"
    scheme.parent.mkdir(parents=True, exist_ok=True)
    ref = lambda id_, name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id_}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:TaskLens.xcodeproj"/>'
    scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app, "TaskLens.app")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(tests, "TaskLensTests.xctest")}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app, "TaskLens.app")}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app, "TaskLens.app")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"Generated {directory.relative_to(ROOT)} ({len(OBJECTS)} objects).")


if __name__ == "__main__":
    main()
