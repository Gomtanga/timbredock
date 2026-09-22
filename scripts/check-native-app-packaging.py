#!/usr/bin/env python3
"""Verify the TimbreDock app name, default output path and localization staging.

Swift, signing and the downloaded products are mocked: this exercises only the
packaging script's naming, resource staging and failure recovery. No audio
device, GUI or network operation happens here.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts/build-native-system-audio-app.sh"
DEFAULT_PARENT = Path("build/LowEndCircuit_artefacts/Release/NativeSystemAudio")
LOCALES = ("en", "ko")


def write_mocks(folder: Path) -> tuple[Path, Path]:
    commands = folder / "commands"
    products = folder / "products"
    commands.mkdir()
    products.mkdir()
    shader = ROOT / "SystemAudioProcessor/Shaders/SpectrumShaders.metal"
    bundle = products / "SystemAudioProcessor_SystemAudioProcessor.bundle"
    bundle.mkdir()
    shutil.copy2(shader, bundle / shader.name)
    for locale in LOCALES:
        locale_dir = bundle / f"{locale}.lproj"
        locale_dir.mkdir()
        for table in ("Localizable", "Main", "Spatial", "Runtime"):
            (locale_dir / f"{table}.strings").write_text(f'"probe" = "{locale}";\n')
    mocks = {
        commands / "swift": '''#!/usr/bin/env python3
import os, sys
if "--show-bin-path" in sys.argv:
    print(os.environ["LOWEND_MOCK_BIN"])
''',
        commands / "codesign": '#!/bin/sh\nexit 0\n',
        products / "LowEndSupportChecks": '#!/bin/sh\nexit 0\n',
        products / "SystemAudioProcessor": '''#!/bin/sh
case "$*" in
  --self-test) exit 0;;
  --help) printf '%s\\n' '--self-test --ui-self-test --benchmark-output-conditioning'; exit 0;;
  *) echo 'Invalid command'; exit 1;;
esac
''',
    }
    for destination, text in mocks.items():
        destination.write_text(text)
        destination.chmod(0o755)
    return commands, products


def isolated_root(folder: Path) -> Path:
    """Copy the packaging script and its inputs into an isolated repository root."""
    root = folder / "repository"
    package = root / "SystemAudioProcessor"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(BUILD_SCRIPT, root / "scripts" / BUILD_SCRIPT.name)
    shutil.copy2(ROOT / "scripts/check-native-cli.py", root / "scripts/check-native-cli.py")
    (package / "Shaders").mkdir(parents=True)
    shutil.copy2(ROOT / "SystemAudioProcessor/Shaders/SpectrumShaders.metal",
                 package / "Shaders/SpectrumShaders.metal")
    (package / "Assets").mkdir()
    shutil.copy2(ROOT / "SystemAudioProcessor/Assets/LowEndNativeAudioIcon.icns",
                 package / "Assets/LowEndNativeAudioIcon.icns")
    for locale in LOCALES:
        destination = package / "Assets/Localization" / f"{locale}.lproj"
        destination.mkdir(parents=True)
        shutil.copy2(ROOT / f"SystemAudioProcessor/Assets/Localization/{locale}.lproj/InfoPlist.strings",
                     destination / "InfoPlist.strings")
    return root


def environment_for(folder: Path, root: Path, commands: Path, products: Path) -> dict:
    environment = os.environ.copy()
    for key in ("LOWEND_APP_DIR", "LOWEND_APP_NAME", "LOWEND_SWIFT_SDK", "LOWEND_SWIFT_BUILD_SYSTEM"):
        environment.pop(key, None)
    environment.update(
        PATH=str(commands) + os.pathsep + environment["PATH"],
        LOWEND_MOCK_BIN=str(products),
        LOWEND_BUILD_DIR=str(folder / "isolated-build"),
        LOWEND_BUILD_NUMBER="777",
    )
    return environment


def check_default_output_and_localization() -> None:
    with tempfile.TemporaryDirectory(prefix="lowend-packaging-check-") as temporary:
        folder = Path(temporary)
        commands, products = write_mocks(folder)
        root = isolated_root(folder)
        script = root / "scripts" / BUILD_SCRIPT.name
        environment = environment_for(folder, root, commands, products)

        result = subprocess.run([str(script)], env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        app = root / DEFAULT_PARENT / "TimbreDock.app"
        assert app.is_dir(), result.stdout
        assert app.parent.name == "NativeSystemAudio"
        built_apps = sorted(path.name for path in app.parent.glob("*.app"))
        assert built_apps == ["TimbreDock.app"], built_apps
        assert (app / "Contents/MacOS/TimbreDock").is_file()
        assert not (app / "Contents/MacOS/LowEnd Native Audio").exists()
        assert (app / "Contents/Resources/SpectrumShaders.metal").is_file()
        assert (app / "Contents/Resources/LowEndNativeAudioIcon.icns").is_file()
        for locale in LOCALES:
            delivered = app / f"Contents/Resources/{locale}.lproj/InfoPlist.strings"
            source = root / f"SystemAudioProcessor/Assets/Localization/{locale}.lproj/InfoPlist.strings"
            assert delivered.read_bytes() == source.read_bytes()
            strings = app / f"Contents/Resources/{locale}.lproj/Localizable.strings"
            assert strings.read_text() == f'"probe" = "{locale}";\n'
        with (app / "Contents/Info.plist").open("rb") as file:
            metadata = plistlib.load(file)
        assert metadata["CFBundleIdentifier"] == "com.codexaudiolab.lowendcircuit.systemaudio"
        assert metadata["CFBundleExecutable"] == "TimbreDock"
        assert metadata["CFBundleName"] == "TimbreDock"
        assert metadata["CFBundleDisplayName"] == "TimbreDock"
        assert metadata["CFBundleShortVersionString"] == "0.4.0"
        assert metadata["CFBundleVersion"] == "777"
        assert metadata["CFBundleLocalizations"] == list(LOCALES)
        assert metadata["LCCaptureLeaseVersion"] == 1
        assert metadata["CFBundleIconFile"] == "LowEndNativeAudioIcon"
        english = (app / "Contents/Resources/en.lproj/InfoPlist.strings").read_text()
        korean = (app / "Contents/Resources/ko.lproj/InfoPlist.strings").read_text()
        assert "TimbreDock captures" in english
        assert korean != english
        assert "TimbreDock\uc740" in korean  # Korean sentence actually reached the bundle
        assert metadata["NSAudioCaptureUsageDescription"].startswith("TimbreDock")
        assert metadata["NSAppleEventsUsageDescription"].startswith("TimbreDock")
        print("PackagingChecks: default output is NativeSystemAudio/TimbreDock.app with en/ko permission strings")

        # A missing localization must fail before the staged bundle replaces the live app.
        (root / "SystemAudioProcessor/Assets/Localization/ko.lproj/InfoPlist.strings").unlink()
        preserved = {str(path.relative_to(app)): path.read_bytes() for path in app.rglob("*") if path.is_file()}
        result = subprocess.run([str(script)], env=environment, capture_output=True, text=True)
        assert result.returncode != 0
        assert {str(path.relative_to(app)): path.read_bytes()
                for path in app.rglob("*") if path.is_file()} == preserved
        assert not list(app.parent.glob(".lowend-stage.*"))
        print("PackagingChecks: a missing localization preserves the previously built app")


def check_legacy_overrides() -> None:
    with tempfile.TemporaryDirectory(prefix="lowend-packaging-legacy-") as temporary:
        folder = Path(temporary)
        commands, products = write_mocks(folder)
        root = isolated_root(folder)
        script = root / "scripts" / BUILD_SCRIPT.name
        environment = environment_for(folder, root, commands, products)
        legacy = folder / "legacy/LowEnd Native Audio.app"
        legacy.mkdir(parents=True)
        result = subprocess.run([str(script)], env=environment | {"LOWEND_APP_DIR": str(legacy)},
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert (legacy / "Contents/MacOS/TimbreDock").is_file()
        with (legacy / "Contents/Info.plist").open("rb") as file:
            assert plistlib.load(file)["CFBundleExecutable"] == "TimbreDock"
        print("PackagingChecks: LOWEND_APP_DIR overrides the path while preserving TimbreDock identity")


def check_launcher_paths() -> None:
    with tempfile.TemporaryDirectory(prefix="lowend-packaging-launcher-") as temporary:
        folder = Path(temporary)
        app = folder / "TimbreDock.app"
        executable = app / "Contents/MacOS/TimbreDock"
        executable.parent.mkdir(parents=True)
        log = folder / "launcher-args.txt"
        executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{log}"\n')
        executable.chmod(0o755)
        environment = os.environ.copy()
        environment.pop("LOWEND_APP_NAME", None)
        environment["LOWEND_APP_DIR"] = str(app)
        result = subprocess.run([str(ROOT / "scripts/list-audio-apps.sh")], env=environment,
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(ROOT / "scripts/run-app-lowend.sh"), "com.example.player"],
                                env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(ROOT / "scripts/run-system-wide-lowend.sh")], env=environment,
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        invocations = log.read_text().splitlines()
        assert invocations == ["--list-apps", "--bundle-id com.example.player", "--all"], invocations
        print("PackagingChecks: run/list launchers resolve Contents/MacOS/TimbreDock")


def check_script_syntax() -> None:
    for script in (BUILD_SCRIPT, ROOT / "scripts/run-app-lowend.sh",
                   ROOT / "scripts/run-system-wide-lowend.sh", ROOT / "scripts/list-audio-apps.sh"):
        result = subprocess.run(["sh", "-n", str(script)], capture_output=True, text=True)
        assert result.returncode == 0, (script, result.stderr)
    compile(Path(__file__).read_text(), str(Path(__file__)), "exec")


def check_package_manifest() -> None:
    manifest = (ROOT / "SystemAudioProcessor/Package.swift").read_text()
    assert 'defaultLocalization: "en"' in manifest
    assert '.process("Resources")' in manifest
    assert 'name: "SystemAudioProcessor"' in manifest
    for locale in LOCALES:
        assert (ROOT / f"SystemAudioProcessor/Sources/SystemAudioProcessor/Resources/{locale}.lproj").is_dir()
    print("PackagingChecks: manifest keeps defaultLocalization en and processes the app Resources")


if __name__ == "__main__":
    check_script_syntax()
    check_package_manifest()
    check_default_output_and_localization()
    check_legacy_overrides()
    check_launcher_paths()
    print("PackagingChecks: Swift/signing are mocked; a signed Release bundle check remains separate")
