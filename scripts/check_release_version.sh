#!/bin/bash
#
# check_release_version.sh — Valida la versión de un release de LCC
#
# La versión es el tag sin la "v" inicial. Formato (ver lib/src/version.dart):
#   preview   <edición>-preview.<build>   27H1-preview.20261105.56
#   estable   <edición>[u<update>]        27H1, 27H1u2
#
# Uso:
#   ./check_release_version.sh expected
#       Imprime la versión que describe lib/src/version.dart.
#   ./check_release_version.sh consistency <versión>
#       Falla si <versión> está mal formada o no coincide con
#       lib/src/version.dart. Imprime "version=..." y "channel=..." (formato
#       de $GITHUB_OUTPUT).
#   ./check_release_version.sh lifecycle <versión> <fichero-de-tags>
#       Falla si publicar <versión> rompe el ciclo de vida de los releases.
#       <fichero-de-tags>: un tag por línea, de los releases ya publicados
#       (sin borradores). Los tags con formato antiguo se ignoran.
#
# Reglas del ciclo de vida:
#   1. Cada release es más nuevo que todos los publicados de su mismo canal.
#      Orden: edición → canal (preview < estable) → update → build.
#   2. Una preview es de una edición que aún no ha salido en estable.
#   3. Un parche estable (update ≥ 1) conserva el build de la estable
#      anterior de su edición, que debe existir.
#   Con 1 y 2, la estable de una edición nueva cierra los parches de la
#   anterior: un parche de una edición cerrada es más viejo que esa estable.
#

set -euo pipefail

# Sin cd: el fichero de tags es relativo al directorio de quien llama.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="lib/src/version.dart"

# En GitHub Actions el error sale como anotación del workflow.
die() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::error::$*" >&2
    else
        echo -e "\033[0;31m✗ ERROR:\033[0m $*" >&2
    fi
    exit 1
}

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//' >&2
    exit "${1:-2}"
}

# ── version.dart ──────────────────────────────────────────────────────────────

# read_const <tipo> <nombre>: valor de "const <tipo> <nombre> = ...;" leído de
# stdin, sin comillas. Exige exactamente una declaración.
read_const() {
    local values
    values="$(sed -nE "s/^const $1 $2 = '?([^';]*)'?;\$/\1/p")"
    [ -n "$values" ] && [ "$(printf '%s\n' "$values" | wc -l)" -eq 1 ] ||
        return 1
    printf '%s' "$values"
}

# load_version_file: rellena V_EDITION, V_UPDATE, V_CHANNEL y V_BUILD desde
# $VERSION_FILE y los valida.
load_version_file() {
    local content
    content="$(cat "$ROOT/$VERSION_FILE")"

    V_EDITION="$(read_const String kEdition <<<"$content")" ||
        die "$VERSION_FILE: kEdition no encontrado"
    V_UPDATE="$(read_const int kUpdate <<<"$content")" ||
        die "$VERSION_FILE: kUpdate no encontrado"
    V_BUILD="$(read_const String kBuild <<<"$content")" ||
        die "$VERSION_FILE: kBuild no encontrado"
    V_CHANNEL="$(read_const ReleaseChannel kChannel <<<"$content")" ||
        die "$VERSION_FILE: kChannel no encontrado"
    V_CHANNEL="${V_CHANNEL#ReleaseChannel.}"

    [[ "$V_EDITION" =~ ^[0-9]{2}H[12]$ ]] ||
        die "$VERSION_FILE: kEdition '$V_EDITION' no es YYH1/YYH2"
    [[ "$V_UPDATE" =~ ^(0|[1-9][0-9]*)$ ]] ||
        die "$VERSION_FILE: kUpdate '$V_UPDATE' no es un entero"
    [[ "$V_BUILD" =~ ^[0-9]{8}\.(0|[1-9][0-9]*)$ ]] ||
        die "$VERSION_FILE: kBuild '$V_BUILD' no es YYYYMMDD.n"
    case "$V_CHANNEL" in
        preview) [ "$V_UPDATE" -eq 0 ] ||
            die "$VERSION_FILE: una preview lleva kUpdate = 0 (tiene $V_UPDATE)" ;;
        stable) ;;
        *) die "$VERSION_FILE: kChannel '$V_CHANNEL' no es preview ni stable" ;;
    esac
}

expected_version() {
    if [ "$V_CHANNEL" = "preview" ]; then
        printf '%s-preview.%s' "$V_EDITION" "$V_BUILD"
    elif [ "$V_UPDATE" -eq 0 ]; then
        printf '%s' "$V_EDITION"
    else
        printf '%s' "${V_EDITION}u${V_UPDATE}"
    fi
}

# ── Versiones de tags ─────────────────────────────────────────────────────────

PREVIEW_RE='^([0-9]{2}H[12])-preview\.([0-9]{8}\.(0|[1-9][0-9]*))$'
STABLE_RE='^([0-9]{2}H[12])(u([1-9][0-9]*))?$'

# parse_version <versión>: rellena P_EDITION, P_UPDATE, P_CHANNEL, P_BUILD
# (vacío en una estable: su tag no lleva build). Falla si no tiene el formato.
parse_version() {
    if [[ "$1" =~ $PREVIEW_RE ]]; then
        P_EDITION="${BASH_REMATCH[1]}"; P_UPDATE=0
        P_CHANNEL=preview;              P_BUILD="${BASH_REMATCH[2]}"
    elif [[ "$1" =~ $STABLE_RE ]]; then
        P_EDITION="${BASH_REMATCH[1]}"; P_UPDATE="${BASH_REMATCH[3]:-0}"
        P_CHANNEL=stable;               P_BUILD=""
    else
        return 1
    fi
}

# edition_number <YYH#>: 27H1 → 271, comparable como entero.
edition_number() {
    printf '%d' "$(( 10#${1:0:2} * 10 + ${1:3:1} ))"
}

# version_key: clave de ancho fijo de la última versión parseada (P_*), que se
# ordena como texto igual que las versiones. El .n del build va como número,
# así 20261105.9 < 20261105.10.
version_key() {
    local rank=1 date=0 n=0
    if [ "$P_CHANNEL" = "preview" ]; then
        rank=0; date="${P_BUILD%.*}"; n="${P_BUILD#*.}"
    fi
    printf '%03d%d%06d%08d%09d' \
        "$(edition_number "$P_EDITION")" "$rank" "$P_UPDATE" \
        "$((10#$date))" "$((10#$n))"
}

# ── Comandos ──────────────────────────────────────────────────────────────────

cmd_consistency() {
    local version="$1" expected
    load_version_file
    expected="$(expected_version)"
    parse_version "$version" ||
        die "versión '$version' mal formada: se espera <edición>-preview.<build> o <edición>[u<update>] (p. ej. $expected)"
    [ "$version" = "$expected" ] ||
        die "versión '$version' no coincide con $VERSION_FILE, que describe '$expected' (tag v$expected)"
    echo "version=$version"
    echo "channel=$P_CHANNEL"
}

cmd_lifecycle() {
    local version="$1" tags_file="$2"
    local new_key new_channel new_edition new_ednum new_update
    local tag v key prev_tag="" prev_update=-1 prev_build

    [ -r "$tags_file" ] || die "no se puede leer '$tags_file'"
    parse_version "$version" || die "versión '$version' mal formada"
    new_key="$(version_key)"; new_channel="$P_CHANNEL"
    new_edition="$P_EDITION"; new_ednum="$(edition_number "$P_EDITION")"
    new_update="$P_UPDATE"

    while IFS= read -r tag || [ -n "$tag" ]; do
        v="${tag#v}"
        parse_version "$v" || continue
        key="$(version_key)"

        if [ "$new_channel" = "preview" ] && [ "$P_CHANNEL" = "stable" ] &&
            [ "$(edition_number "$P_EDITION")" -ge "$new_ednum" ]; then
            die "la edición $P_EDITION ya salió en estable ($tag): las previews van en una edición posterior"
        fi

        [ "$P_CHANNEL" = "$new_channel" ] || continue

        if [ "$new_channel" = "stable" ] &&
            [ "$(edition_number "$P_EDITION")" -gt "$new_ednum" ]; then
            die "la edición $new_edition está cerrada: ya se publicó la estable $P_EDITION ($tag), así que $new_edition no recibe más parches"
        fi
        if [[ ! "$new_key" > "$key" ]]; then
            if [ "$v" = "$version" ]; then
                die "v$version ya está publicado"
            fi
            die "v$version no es más nuevo que $tag, ya publicado en el canal $new_channel"
        fi

        # Estable anterior de la misma edición, para la regla 3.
        if [ "$P_CHANNEL" = "stable" ] && [ "$P_EDITION" = "$new_edition" ] &&
            [ "$P_UPDATE" -gt "$prev_update" ]; then
            prev_tag="$tag"; prev_update="$P_UPDATE"
        fi
    done <"$tags_file"

    if [ "$new_channel" = "stable" ] && [ "$new_update" -gt 0 ]; then
        [ -n "$prev_tag" ] ||
            die "v$version es un parche de $new_edition, pero no hay ninguna estable $new_edition publicada"
        load_version_file
        prev_build="$(git -C "$ROOT" show "$prev_tag:$VERSION_FILE" 2>/dev/null |
            read_const String kBuild)" ||
            die "no se pudo leer kBuild de $VERSION_FILE en $prev_tag (¿faltan los tags en el checkout?)"
        [ "$V_BUILD" = "$prev_build" ] ||
            die "un parche estable conserva el build: $prev_tag tiene $prev_build y $VERSION_FILE tiene $V_BUILD"
    fi

    echo "Ciclo de vida correcto para v$version" >&2
}

case "${1:-}" in
    expected)
        [ $# -eq 1 ] || usage
        load_version_file
        expected_version; echo
        ;;
    consistency)
        [ $# -eq 2 ] || usage
        cmd_consistency "$2"
        ;;
    lifecycle)
        [ $# -eq 3 ] || usage
        cmd_lifecycle "$2" "$3"
        ;;
    --help|-h)
        usage 0
        ;;
    *)
        usage
        ;;
esac
