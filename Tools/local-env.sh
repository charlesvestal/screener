# Sourced by the Tools/*.sh scripts. Loads per-machine settings (device and
# simulator UDIDs, bundle id) from Tools/local.env, which is git-ignored; see
# Tools/local.env.example. The file holds plain KEY=value lines and is parsed,
# never sourced. Variables already set in the environment win.
#
# Only these keys are read: SCREENER_DEVICE_UDID, SCREENER_SIM_UDID,
# SCREENER_BUNDLE_ID. Never put credentials here (use make-test-env.sh).

_screener_local_env="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/local.env"
if [[ -f $_screener_local_env ]]; then
  while IFS= read -r _line || [[ -n $_line ]]; do
    _line=${_line%$'\r'}
    [[ $_line =~ ^[[:space:]]*# || $_line != *=* ]] && continue
    _key=${_line%%=*}; _value=${_line#*=}
    case $_key in
      SCREENER_DEVICE_UDID|SCREENER_SIM_UDID|SCREENER_BUNDLE_ID)
        [[ -z ${!_key:-} ]] && export "$_key=$_value" ;;
    esac
  done < "$_screener_local_env"
fi
unset _screener_local_env _line _key _value
: "${SCREENER_BUNDLE_ID:=com.vestal.screener}"

# require_env NAME HINT — exits with a hint when NAME is unset or empty.
require_env() {
  if [[ -z ${!1:-} ]]; then
    echo "Set $1 in the environment or in Tools/local.env ($2)." >&2
    exit 2
  fi
}
