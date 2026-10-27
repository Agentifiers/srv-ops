#!/usr/bin/env python3
"""Info.plist work for expo-ios (what Xcode's ProcessInfoPlistFile does).

  plist_tool.py info-plist SETTINGS.json OUT [PARTIAL.plist ...]
      SETTINGS.json: {"src": template, "settings": {build settings}, "sdk": iPhoneOS.sdk,
                      "xcode_version_plist": optional, "release": bool, "device_family": "1,2"}
      Expands $(VAR) / ${VAR} / $(VAR:rfc1034identifier), merges partial plists (asset catalog,
      storyboards), adds the DT*/platform keys Xcode adds, strips the dev-client's local-network
      keys in Release, and writes a binary plist.
  plist_tool.py check-app APP.app       sanity checks of a finished bundle's Info.plist
  plist_tool.py get PLIST KEY           print one value (JSON)
  plist_tool.py framework-info OUT NAME BUNDLE_ID MIN_IOS   minimal framework Info.plist
"""
import json
import os
import plistlib
import re
import sys

VAR = re.compile(r"\$[({]([A-Za-z0-9_]+)(?::([A-Za-z0-9_,]+))?[)}]")


def rfc1034(value):
    return re.sub(r"[^A-Za-z0-9.-]", "-", value)


def expand(value, settings, missing):
    if isinstance(value, str):
        def sub(m):
            name, mod = m.group(1), m.group(2)
            if name not in settings:
                missing.add(name)
                return ""
            v = str(settings[name])
            v = VAR.sub(sub, v)
            if mod and "rfc1034identifier" in mod:
                v = rfc1034(v)
            if mod and "c99extidentifier" in mod:
                v = re.sub(r"[^A-Za-z0-9_]", "_", v)
            return v
        return VAR.sub(sub, value)
    if isinstance(value, list):
        return [expand(v, settings, missing) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, settings, missing) for k, v in value.items()}
    return value


def info_plist(cfg_path, out, partials):
    cfg = json.load(open(cfg_path))
    settings = cfg["settings"]
    missing = set()
    info = expand(plistlib.load(open(cfg["src"], "rb")), settings, missing)
    # Variables Xcode leaves empty when unset; anything else unresolved is a bug.
    unexpected = missing - {"RCT_METRO_PORT", "DEVELOPMENT_TEAM", "APP_DISPLAY_NAME"}
    if unexpected:
        sys.exit(f"Info.plist: unresolved build settings: {', '.join(sorted(unexpected))}")
    if "RCTMetroPort" in info and not info["RCTMetroPort"]:
        del info["RCTMetroPort"]  # RCT_METRO_PORT unset: RN falls back to 8081
    for p in partials:
        info.update(plistlib.load(open(p, "rb")))

    sdk = cfg.get("sdk")
    families = [int(x) for x in str(cfg.get("device_family", "1")).split(",") if x.strip()]
    info.update({
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "DTPlatformName": "iphoneos",
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
        "MinimumOSVersion": settings["IPHONEOS_DEPLOYMENT_TARGET"],
        "UIDeviceFamily": families,
    })
    if sdk:
        sdk_version = json.load(open(os.path.join(sdk, "SDKSettings.json")))["Version"]
        sdk_build = plistlib.load(open(os.path.join(sdk, "System/Library/CoreServices/SystemVersion.plist"), "rb"))["ProductBuildVersion"]
        info.update({
            "DTPlatformVersion": sdk_version,
            "DTSDKName": f"iphoneos{sdk_version}",
            "DTSDKBuild": sdk_build,
            "DTPlatformBuild": sdk_build,
        })
    else:
        print("warning: no iPhoneOS SDK; DTSDK*/DTPlatform* keys left out", file=sys.stderr)
    info.pop("LSMinimumSystemVersion", None)  # macOS-only key the template carries
    xv = cfg.get("xcode_version_plist")
    if xv and os.path.exists(xv):
        v = plistlib.load(open(xv, "rb"))
        short = v.get("CFBundleShortVersionString", "")
        parts = (short.split(".") + ["0", "0"])[:3]
        info["DTXcode"] = f"{int(parts[0]):02d}{parts[1]}{parts[2]}"
        if "ProductBuildVersion" in v:
            info["DTXcodeBuild"] = v["ProductBuildVersion"]
    if cfg.get("release"):
        # expo-dev-client's plugin adds Bonjour/local-network keys for Metro discovery;
        # its Release build phase strips them again.
        bonjour = [s for s in info.get("NSBonjourServices", []) if s != "_expo._tcp"]
        if "NSBonjourServices" in info:
            if bonjour:
                info["NSBonjourServices"] = bonjour
            else:
                del info["NSBonjourServices"]
                desc = info.get("NSLocalNetworkUsageDescription", "")
                if "Expo" in desc or "development server" in desc:
                    del info["NSLocalNetworkUsageDescription"]
    for key in ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
        if not info.get(key):
            sys.exit(f"Info.plist: {key} is empty after expansion")
    plistlib.dump(info, open(out, "wb"), fmt=plistlib.FMT_BINARY)


def check_app(app):
    info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
    errors = []
    exe = info.get("CFBundleExecutable")
    if not exe or not os.path.isfile(os.path.join(app, exe)):
        errors.append(f"CFBundleExecutable {exe!r} missing from bundle")
    for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "MinimumOSVersion",
                "UIDeviceFamily", "CFBundlePackageType", "DTPlatformName"):
        if key not in info:
            errors.append(f"missing {key}")
    if info.get("CFBundlePackageType") != "APPL":
        errors.append(f"CFBundlePackageType is {info.get('CFBundlePackageType')!r}")
    if info.get("UILaunchStoryboardName") and not os.path.isdir(os.path.join(app, info["UILaunchStoryboardName"] + ".storyboardc")):
        errors.append(f"UILaunchStoryboardName {info['UILaunchStoryboardName']} has no .storyboardc")
    # actool's partial plist puts the icon name under CFBundleIcons~*/CFBundlePrimaryIcon.
    icon = info.get("CFBundleIconName") or next(
        (v["CFBundlePrimaryIcon"].get("CFBundleIconName") for k, v in info.items()
         if k.startswith("CFBundleIcons") and isinstance(v, dict) and isinstance(v.get("CFBundlePrimaryIcon"), dict)), None)
    if icon and not os.path.isfile(os.path.join(app, "Assets.car")):
        errors.append(f"icon {icon} set but no Assets.car")
    if errors:
        sys.exit("Info.plist check failed:\n  " + "\n  ".join(errors))
    summary = {k: info.get(k) for k in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                                         "CFBundleVersion", "MinimumOSVersion", "UILaunchStoryboardName", "DTSDKName")}
    summary["CFBundleIconName"] = icon
    print(json.dumps(summary))


def framework_info(out, name, bundle_id, min_ios):
    plistlib.dump({
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": name,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": "1.0",
        "CFBundleSignature": "????",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": min_ios,
    }, open(out, "wb"), fmt=plistlib.FMT_XML)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "info-plist":
        info_plist(args[0], args[1], args[2:])
    elif cmd == "check-app":
        check_app(args[0])
    elif cmd == "get":
        print(json.dumps(plistlib.load(open(args[0], "rb")).get(args[1])))
    elif cmd == "framework-info":
        framework_info(*args)
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
