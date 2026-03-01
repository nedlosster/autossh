#!/bin/bash
# Сборка deb/rpm пакетов auto-ssh-tunnels
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_NAME="auto-ssh-tunnels"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"

BUILD_DIR="$SCRIPT_DIR/_build"
OUT_DIR="$SCRIPT_DIR/_out"

# --- Подготовка дерева файлов (общая для deb и rpm) ---
prepare_tree() {
    local root="$1"
    rm -rf "$root"

    # /usr/sbin/auto-ssh-tunnels
    install -Dm755 "$PROJECT_DIR/setup.sh" "$root/usr/sbin/${PKG_NAME}"

    # /usr/lib/auto-ssh-tunnels/
    install -Dm644 "$PROJECT_DIR/lib.sh"          "$root/usr/lib/${PKG_NAME}/lib.sh"
    install -Dm644 "$PROJECT_DIR/generate.sh"     "$root/usr/lib/${PKG_NAME}/generate.sh"
    install -Dm755 "$PROJECT_DIR/parse-config.py"  "$root/usr/lib/${PKG_NAME}/parse-config.py"

    # /etc/auto-ssh-tunnels/config.yml
    install -Dm644 "$PROJECT_DIR/config.yml.example" "$root/etc/${PKG_NAME}/config.yml"
}

# --- Сборка deb ---
build_deb() {
    echo "==> Сборка deb пакета v${VERSION}"

    local root="$BUILD_DIR/deb-root"
    prepare_tree "$root"

    # DEBIAN
    local debian="$root/DEBIAN"
    mkdir -p "$debian"

    sed "s/@VERSION@/${VERSION}/g" "$SCRIPT_DIR/deb/control" > "$debian/control"
    cp "$SCRIPT_DIR/deb/conffiles"  "$debian/conffiles"
    install -m755 "$SCRIPT_DIR/deb/postinst" "$debian/postinst"
    install -m755 "$SCRIPT_DIR/deb/prerm"    "$debian/prerm"
    install -m755 "$SCRIPT_DIR/deb/postrm"   "$debian/postrm"

    mkdir -p "$OUT_DIR"
    dpkg-deb --build "$root" "$OUT_DIR/${PKG_NAME}_${VERSION}_all.deb"
    echo "==> $OUT_DIR/${PKG_NAME}_${VERSION}_all.deb"
}

# --- Сборка rpm ---
build_rpm() {
    echo "==> Сборка rpm пакета v${VERSION}"

    local rpmbuild_dir="$BUILD_DIR/rpmbuild"
    rm -rf "$rpmbuild_dir"
    mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Подготовка tarball
    local tarball_name="${PKG_NAME}-${VERSION}"
    local tar_root="$BUILD_DIR/${tarball_name}"
    prepare_tree "$tar_root"

    tar -czf "$rpmbuild_dir/SOURCES/${tarball_name}.tar.gz" \
        -C "$BUILD_DIR" "${tarball_name}"

    # Копируем скрипты для %post/%preun/%postun
    cp "$SCRIPT_DIR/deb/postinst" "$rpmbuild_dir/SOURCES/postinst.sh"
    cp "$SCRIPT_DIR/deb/prerm"    "$rpmbuild_dir/SOURCES/prerm.sh"
    cp "$SCRIPT_DIR/deb/postrm"   "$rpmbuild_dir/SOURCES/postrm.sh"

    sed "s/@VERSION@/${VERSION}/g" "$SCRIPT_DIR/rpm/${PKG_NAME}.spec" \
        > "$rpmbuild_dir/SPECS/${PKG_NAME}.spec"

    rpmbuild --define "_topdir $rpmbuild_dir" \
        -bb "$rpmbuild_dir/SPECS/${PKG_NAME}.spec"

    mkdir -p "$OUT_DIR"
    find "$rpmbuild_dir/RPMS" -name '*.rpm' -exec cp {} "$OUT_DIR/" \;
    echo "==> rpm пакеты скопированы в $OUT_DIR/"
    ls "$OUT_DIR/"*.rpm 2>/dev/null || true
}

# --- Очистка ---
clean() {
    echo "==> Очистка"
    rm -rf "$BUILD_DIR" "$OUT_DIR"
    echo "==> Очищено"
}

# --- Main ---
case "${1:-}" in
    deb)   build_deb ;;
    rpm)   build_rpm ;;
    all)   build_deb; build_rpm ;;
    clean) clean ;;
    *)
        echo "Использование: $0 {deb|rpm|all|clean}"
        exit 1
        ;;
esac
