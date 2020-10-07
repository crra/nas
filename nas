#!/usr/bin/env bash
# non-substantial portions taken from https://github.com/ralish/bash-script-template

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

readonly WAKE_ON_LAN_COMMAND="wakeonlan"

function _error() {
	local -r msg=${1:-}

	echo -e "Error: $msg" 1>&2
	exit 1
}

function _print() {
	printf '%s%b\n' "$1" "$ta_none"
}

function _info() {
	_print "$@"
}

function _verbose() {
	if [[ -n ${VERBOSE-} ]]; then
		_print "$@"
	fi
}

# after the config file is sourced (imported in the script scope)
# ensure that mandatory and optional environment variables are set
function ensureEnvVariables() {
	local -r exampleFile=${1:-}

	if [ ! -e "$exampleFile" ]; then
		_error "Can't open example file '$exampleFile'"
	fi

	# Read the file into an array (for bash <4)
	local lines=()
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line##*( )}"
		# Ignore empty lines
		if [ -n "$line" ]; then
			lines+=("$line")
		fi
	done <"$exampleFile"

	# very simple parser
	# Gramar: # (mandatory|optional): TEXT \n config_NAME = VALUE
	local -i i
	for ((i = 0; i <= "${#lines[@]}-1"; i++)); do
		local line="${lines[$i]}"

		# Must be a type annotation for the following variable
		if [[ $line =~ (mandatory|optional) ]]; then
			local isType="${BASH_REMATCH[1]##*( )}"

			if [ $((i + 1)) -gt ${#lines[@]} ]; then
				_error "Can't peek into next line at index '$($i + 1)'"
			fi

			# Move cursor to next line to consume tokens
			((i++))

			local nextLine=${lines[$i]##*( )}
			# Variable declaration and assignment
			if [[ $nextLine =~ ^(config_.+)=(.+)$ ]]; then
				local varName="${BASH_REMATCH[1]##*( )}"
				local defaultValue="${BASH_REMATCH[2]##*( )}"
				# replace quotes separatly, because batch regex is always greedy
				defaultValue=${defaultValue#\"}
				defaultValue=${defaultValue%\"}

				if [ -z ${!varName+x} ]; then
					if [ "$isType" = 'mandatory' ]; then
						_error "Mandatory variable '$varName' not defined in configfile"
					else
						_verbose "Variabe '$varName' will use default value '$defaultValue'"
						# bash <4 lacks the '-g' option
						eval "$varName=$defaultValue"
					fi
				fi
			else
				_error "Line '$nextLine' must be a config variable assignment"
			fi
		else
			_error "Can't parse line '$line' from '$exampleFile'"
		fi
	done
}

function usage() {
	cat <<EOF
Usage: nas [options] [commmand]

Options:
     -h|--help                  Displays this help
     -v|--verbose               Displays verbose output

Commands:
     up                         wakes the NAS and connect the shares
     down                       shuts down the NAS via SSH
EOF
}

function isHostPortOpen() {
	local -r host=${1:-}
	local -r port=${2:-}
	local -r timeout=${3:1}

	if [ -z "$host" ]; then error "host not defined"; fi
	if [ -z "$port" ]; then error "port not defnined"; fi

	_verbose "Checking port '$port' at host '$host'"

	nc -v -z -w "$timeout" "$host" "$port" &>/dev/null
}

function mountShares() {
	local host=${1:-}

	if [ -z "$host" ]; then error "host not defined"; fi

	IFS=', ' read -r -a shares <<<"${2:-}"

	# mounting is currently supported on macOS only
	if [[ "$OSTYPE" == "darwin"* ]]; then
		for s in "${shares[@]}"; do
			osascript -e 'mount volume ("smb://'"$host"'/'"$s"'")'
		done
	fi
}

function up() {
	if ! command -v "$WAKE_ON_LAN_COMMAND" &>/dev/null; then
		echo "$OSTYPE"
		if [[ "$OSTYPE" == "darwin"* ]]; then
			_error "Wake on lan is not installed. You may want to use brew (https://brew.sh/) and then 'brew install wakeonlan'"
		else
			_error "Wake on lan is not installed. Check your distribution or install from 'https://github.com/jpoliv/wakeonlan'"
		fi
	fi

	if ! isHostPortOpen "$config_hostname" "$config_up_test_port"; then
		_info "Host '$config_hostname' is not reachable on port '$config_up_test_port', trying to wake it up"

		# macOS can't use netcat due to the missing '-b' flag, so it need to rely on the external
		# wakeonlan program
		# TODO: the wakeonlan program is implemented in perl, find a better substitute
		"$WAKE_ON_LAN_COMMAND" "$config_mac" >/dev/null

		_verbose "Wake on lan request sent, waiting for '$config_delay_after_wol_seconds' seconds before any further attempt"
		sleep "$config_delay_after_wol_seconds"

		# This is an infinite, but no busy loop. The timeout during the port check
		# acts as a deleay between the calls. To avoid to loop forever only a limited
		# amount
		local -i attempts=0

		until isHostPortOpen "$config_hostname" "$config_up_test_port" "$config_up_timeout_seconds"; do
			if ((attempts >= config_up_retries)); then
				_error "NAS was not reachable within the expected time. Please check your setup and raising the timeouts may help"
			else
				_verbose "Attempt '#$attempts' failed! Trying again"
				((attempts++))
			fi
		done
	else
		_info "Host '$config_hostname' is reachable"
	fi

	if [ -n "$config_shares" ]; then
		mountShares "$config_hostname" "${config_shares[@]}"
	fi
}

function down() {
	if ! isHostPortOpen "$config_hostname" "$config_ssh_port"; then
		_info "Host '$config_hostname' seams to be down already or is shutting down"
		return
	fi

	_info "Host '$config_hostname' is up, trying to shutdown via ssh"
	ssh -t "$config_ssh_user@$config_hostname" 'poweroff'
}

function main() {
	readonly ta_none="$(tput sgr0 2>/dev/null || true)"

	local positional=()
	while [[ $# -gt 0 ]]; do
		case $1 in
		-h)
			usage
			exit 0
			;;
		-v)
			VERBOSE=true
			shift
			;;
		*)
			positional+=("$1")
			shift
			;;
		esac
	done
	# bash <4 throws an error on empty array
	if [ ${#positional[@]} -gt 0 ]; then
		set -- "${positional[@]}"
	fi

	local -r envFile="$HOME/.config/nas/nas"
	local -r exampleFile="$(dirname "${BASH_SOURCE[1]}")/nas.env.example"

	if [ ! -f "$envFile" ]; then
		_error "configuration file '$envFile' not found. Copy and adjust '$exampleFile'"
	fi

	# bash <4 does not handle asscociative arrays well
	# therefore the values are sourced = imported into the script scope
	# shellcheck source=nas.env.example
	source "$envFile"
	ensureEnvVariables "$exampleFile"

	case "${1:-}" in
	up) up ;;
	down) down ;;
	*)
		usage
		exit 1
		;;
	esac
}

main "$@"
