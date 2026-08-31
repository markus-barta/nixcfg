#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  printf 'reason_code=projection_validator_arguments_invalid value_returned=false\n' >&2
  exit 2
fi

stat_bin="$1"
expected_uid="$2"
expected_gid="$3"
validation_root="${4%/}"
projected_file="$5"
[ -n "${validation_root}" ] || validation_root=/

case "${expected_uid}:${expected_gid}" in
*[!0-9:]* | :* | *:)
  printf 'reason_code=projection_validator_arguments_invalid value_returned=false\n' >&2
  exit 2
  ;;
esac
case "${validation_root}:${projected_file}" in
/*:/*) ;;
*)
  printf 'reason_code=projection_path_invalid value_returned=false\n' >&2
  exit 1
  ;;
esac

projected_parent="${projected_file%/*}"
if [ "${validation_root}" = / ]; then
  relative_parent="${projected_parent#/}"
else
  case "${projected_parent}" in
  "${validation_root}") relative_parent= ;;
  "${validation_root}"/*) relative_parent="${projected_parent#"${validation_root}"/}" ;;
  *)
    printf 'reason_code=projection_path_invalid value_returned=false\n' >&2
    exit 1
    ;;
  esac
fi

validate_parent() {
  parent="$1"
  final="$2"
  if [ -L "${parent}" ]; then
    printf 'reason_code=projection_parent_symlink value_returned=false\n' >&2
    exit 1
  fi
  if [ ! -d "${parent}" ]; then
    printf 'reason_code=projection_parent_missing value_returned=false\n' >&2
    exit 1
  fi
  owner="$(${stat_bin} -c '%u:%g' -- "${parent}")" || {
    printf 'reason_code=projection_parent_unreadable value_returned=false\n' >&2
    exit 1
  }
  if [ "${owner}" != "${expected_uid}:${expected_gid}" ]; then
    printf 'reason_code=projection_parent_owner_mismatch value_returned=false\n' >&2
    exit 1
  fi
  mode="$(${stat_bin} -c '%a' -- "${parent}")" || {
    printf 'reason_code=projection_parent_unreadable value_returned=false\n' >&2
    exit 1
  }
  if [ $((0${mode} & 022)) -ne 0 ]; then
    printf 'reason_code=projection_parent_writable value_returned=false\n' >&2
    exit 1
  fi
  if [ "${final}" = true ] && [ $((0${mode} & 077)) -ne 0 ]; then
    printf 'reason_code=projection_parent_not_private value_returned=false\n' >&2
    exit 1
  fi
}

current_parent="${validation_root}"
if [ -z "${relative_parent}" ]; then
  validate_parent "${current_parent}" true
else
  validate_parent "${current_parent}" false
  remaining="${relative_parent}"
  while [ -n "${remaining}" ]; do
    component="${remaining%%/*}"
    if [ "${remaining}" = "${component}" ]; then
      remaining=
    else
      remaining="${remaining#*/}"
    fi
    [ -n "${component}" ] || {
      printf 'reason_code=projection_path_invalid value_returned=false\n' >&2
      exit 1
    }
    current_parent="${current_parent%/}/${component}"
    if [ "${current_parent}" = "${projected_parent}" ]; then
      validate_parent "${current_parent}" true
    else
      validate_parent "${current_parent}" false
    fi
  done
fi

if [ -L "${projected_file}" ] || [ ! -f "${projected_file}" ]; then
  if [ ! -e "${projected_file}" ] && [ ! -L "${projected_file}" ]; then
    reason=projection_missing
  else
    reason=projection_not_regular
  fi
  printf 'reason_code=%s value_returned=false\n' "${reason}" >&2
  exit 1
fi
owner="$(${stat_bin} -c '%u:%g' -- "${projected_file}")" || {
  printf 'reason_code=projection_unreadable value_returned=false\n' >&2
  exit 1
}
if [ "${owner}" != "${expected_uid}:${expected_gid}" ]; then
  printf 'reason_code=projection_owner_mismatch value_returned=false\n' >&2
  exit 1
fi
if [ "$(${stat_bin} -c '%a' -- "${projected_file}")" != 600 ]; then
  printf 'reason_code=projection_not_private value_returned=false\n' >&2
  exit 1
fi
