#!/usr/bin/env bash
# Final Fantasy XIV Online wrapper with some additional niceties
#
# Author: XenHat (me@xenh.at)
# This work is licensed under the terms of the MIT license.
# For a copy, see <https://opensource.org/licenses/MIT>.
#
# The latest version of this script should be available at:

# https://gitlab.com/XenHat/dotfiles/-/blob/main/snowblocks/scripts/scripts/FinalFantasyXIVOnline
#
# The Discord RPC glue logic has been moved to a service. You can get a copy at
# https://gitlab.com/XenHat/dotfiles/-/blob/main/snowblocks/scripts/scripts/ffxiv_rpc_service
#
### USAGE ###
# This script is a wrapper. Run this script instead of XIVLauncher/XLCore.
# I use a desktop entry as follows:
#  cat ~/.local/share/applications/LaunchFFXIV.desktop
#     [Desktop Entry]
#     Encoding=UTF-8
#     Exec=bash -c '$HOME/scripts/FinalFantasyXIVOnline'
#     GenericName=Final Fantasy XIV Online Bash Wrapper
#     Icon=ffxiv
#     MimeType=
#     Name=Final Fantasy XIV Online
#     Path=
#     StartupNotify=true
#     Terminal=false
#     TerminalOptions=
#     Type=Application
#     Version=1.0
#     X-KDE-SubstituteUID=false
#     X-KDE-Username=
#EOF
#
# The icon and desktop file are inside the repository as well.
#
#

#TODO: use trap to kill sub processes : https://stackoverflow.com/a/20165094
_xlcore_data_folder="$HOME/.xlcore"
_launcher_bin=""
_wine_executable=""
_launcher_config_dir="$HOME/.xlcore"
_launcher_ini="$_launcher_config_dir/launcher.ini"

get_systemd_session_type() {
	# Get systemd session type
	session_from_systemd=$(loginctl show-session "$(awk '/tty/ {print $1}' <(loginctl list-sessions | grep "$USER" | grep "active" -w))" -p Type | awk -F= '{print $2}')
	if [[ -n $session_from_systemd ]]; then
		echo "$session_from_systemd"
		exit 0
	else
		environment=$(env)
		if grep -qc "WAYLAND_DISPLAY" <<<"$environment"; then
			echo "wayland"
			exit 0
		elif grep -qc "DISPLAY" <<<"$environment"; then
			echo "x11"
			exit 0
		fi
	fi
	echo "none"
	exit 1
}

find_xlcore_bin() {
	if [[ -f /opt/xivlauncher/openssl_fix.cnf ]]; then
		# XIVLauncher was installed with the OpenSSL fix, let's use it.
		OPENSSL_CONF=/opt/xivlauncher/openssl_fix.cnf
		export OPENSSL_CONF
		cmd_path=/opt/xivlauncher/XIVLauncher.Core
	else
		echo "# Absolute minimum openssl config that works on Fedora 36
		# Fixes SSL error when logging in
		# This is NOT SAFE to use as system default. Do not replace your
		# system openssl.cnf with this file.

		openssl_conf = openssl_init

		[openssl_init]
		ssl_conf = ssl_module

		[ ssl_module ]
		system_default = crypto_policy

		[ crypto_policy ]
		MinProtocol = TLSv1.2
		CipherString = DEFAULT:@SECLEVEL=1
		" >/tmp/xiv_ssl.cnf
		OPENSSL_CONF=/tmp/xiv_ssl.cnf
		export OPENSSL_CONF
	fi
	# FIXME: command -v aborts the script on failure
	set +e
	if [[ -z $cmd_path ]]; then
		cmd_path=$(command -v XIVLauncher.Core)
	fi
	if [[ -z $cmd_path ]]; then
		echo "Trying to find fallback path for xivlauncher"
		cmd_path=$(command -v xivlauncher)
	fi
	if [[ -z $cmd_path ]]; then
		cmd_path=$(command -v xivlauncher-core) # Shouldn't happen, but included for safety
	fi
	if [[ -z $cmd_path ]]; then
		if flatpak list | grep -q -w dev.goats.xivlauncher; then
			_extra_parameters=('--filesystem=xdg-run/discord:create')
			echo "Found flatpak for XIVLauncher"
			cmd_path="flatpak run dev.goats.xivlauncher"
			echo "============== WARNING ================="
			echo "Rich Presence does NOT currently work with the flatpak version of XIVLauncher"
			echo "The cause is unclear, any hint is appreciated. Pull requests are welcome!"
			echo "WORKAROUND: Install XIVLauncher natively (Arch Linux and Fedora are supported atm)"
			echo "Arch Linux:     AUR (xivlauncher-git)"
			echo "Fedora-like:    https://copr.fedorainfracloud.org/coprs/rankyn/xivlauncher/"
		fi
	fi
	_launcher_bin="$cmd_path"
	echo "xivlauncher path: '$_launcher_bin'"
}
# NOTE: Reminder: in Unix-like OSes, false==1 and true==0; see
# https://tldp.org/LDP/abs/html/exitcodes.html#EXITCODESREF
is_xlcore_running() {
	pgrep -i xivlauncher >/dev/null 2>&1
	return $?
}
is_xiv_running() {
	pgrep -i ffxiv_dx11 >/dev/null 2>&1
	return $?
}
is_discord_running() {
	if pgrep -x discord >/dev/null 2>&1; then
		return 0
	fi
	if pgrep -x Discord >/dev/null 2>&1; then
		return 0
	fi
	if pgrep -i vesktop >/dev/null 2>&1; then
		return 0
	fi
	return 1
}
is_bridge_running() {
	if pgrep -f winediscordipcbridge.exe >/dev/null 2>&1; then
		return 0
	fi
	return 1
}
is_teamcraft_running() {
	_teamcraft_pid=$(pgrep -f FFXIV\ Teamcraft.exe 2>/dev/null)
	return $?
}

start_xlcore() {
	if [[ -n $_launcher_bin ]]; then
		# The following parameters are for the flatpak version
		#LD_PRELOAD="" XL_SECRET_PROVIDER=FILE $_launcher_bin run --parent-expose-pids --parent-share-pids --parent-pid=1 --branch=stable --arch=x86_64 --command=xivlauncher &
		# We need to fork here so that the rest of the script executes

		$_launcher_bin "${_extra_parameters[@]}" >/dev/null 2>&1 &
		until is_xlcore_running; do
			echo 'Waiting on the launcher to start'
			sleep 1
		done
	else
		echo >&2 "XIVLauncher not found!"
		exit 1
	fi
}

wait_for_game() {
	echo 'Waiting for game to start'
	#TODO: use a file watch for the env file instead
	#TODO Get and compare XLCore's pid instead
	until is_xiv_running; do
		if ! is_xlcore_running; then
			echo "Launcher exited! Aborting!"
			exit 2
		fi
		# Continuously update settings until the game has been started
		# This should work around race conditions related to wine path
		get_wine_binary
		sleep 1
	done
	echo "Game has been started, continuing"
}

get_wine_binary() {
	##########################################################################
	#							WARNING
	# Changing the wine binary (and consequently regenerating the prefix)
	# has a very high likelyhood of breaking dalamud plugins, leading to
	# the game launch being stuck.
	# If you are here because you are trying to fix this issue,
	# do the following:
	# mv ~/.xlcore/installedPlugins ~/.xlcore/installedPlugins.old
	#
	# You should be able to launch the game afterwards.

	# Is wine version managed by xivlauncher?
	wine_type=$(grep -F WineStartupType "$_launcher_ini" | cut -d '=' -f 2)
	if [[ -z $wine_type ]]; then
		echo >&2 "Error: Parsing XLCore config has failed"
		exit 4
	fi
	#FIXME: Need to test managed again for proper path
	if [[ $wine_type == "Managed" ]]; then
		echo "Using managed wine path"
		# Crude but until XLCore exposes this, it will have to do...
		_wine_binary_path=$(dirname "$(find "$HOME"/.xlcore/compatibilitytool/ -type f -name wine)")
	else
		#custom wine path
		echo "Using custom wine path"
		_xlcore_wine_binary_path_setting=$(grep -F WineBinaryPath "$_launcher_ini" | cut -d '=' -f 2)
		echo "XLCore Configured Custom Wine Path: '${_xlcore_wine_binary_path_setting}'"
		_wine_binary_path="$_xlcore_wine_binary_path_setting"
	fi
	_wine_executable=${_wine_binary_path}/wine
	echo "Wine Executable: '$_wine_executable'"
	if [[ ! -f $(readlink -f "$_wine_executable") ]]; then
		echo "Wine executable doesn't exist!!!"
		#exit 1
	fi
}
load_settings_from_xlcore() {
	# Additional wine processes need to run using the same wine binary and the
	# same FSYNC/ESYNC/FUTEX2/etc parameters, otherwise it will fail, or crash.
	# Read the launcher configuration after the game has been launched
	# in case the user edited the configuration

	if grep -Fxq 'ESyncEnabled=true' "$_launcher_ini"; then
		WINEESYNC=1
	else
		WINEESYNC=0
	fi
	if grep -Fxq 'FSyncEnabled=true' "$_launcher_ini"; then
		WINEFSYNC=1
	else
		WINEFSYNC=0
	fi
	export WINEESYNC WINEFSYNC
}

apply_fixups() {
	# HACK: Force a dalamud startup delay if reshade is found
	if [[ -f "$_launcher_config_dir/ffxiv/game/dxgi.dll" ]]; then
		# This only works when using DLL Injection method, not entrypoint
		sed -i 's/^DalamudLoadMethod=EntryPoint$/DalamudLoadMethod=DllInject/' "$_launcher_ini"
		sed -i 's/^DalamudLoadDelay=.*$/DalamudLoadDelay=10000/' "$_launcher_ini"
		# This only works if waiting for plugins is disabled, so force it off
		sed -i 's/.*"IsResumeGameAfterPluginLoad"\: true,/\ \ "IsResumeGameAfterPluginLoad": false,/' "$_launcher_config_dir/dalamudConfig.json"
	fi
	#set_wayland_workaround
}
#TODO: Clean up and deduplicate

clone_live_game_env() {
	# Load the environment variables from the running process
	# FIXME: Running wine with CAP_SYS_ADMIN will require running this script
	# with the same permissions in order to read the environment file.
	game_pid=$(pgrep ffxiv_dx11 | tail -n1)
	process_file="/proc/${game_pid}/environ"
	env_file=$HOME/.cache/ffxiv_env
	rm -f "$env_file"
	if [[ -f ${process_file} ]]; then
		while IFS= read -r -d $'\0' file; do
			if
				[[ $file =~ XDG_ ]] ||
					[[ $file =~ DXVK ]] ||
					[[ $file =~ PROTON ]] ||
					[[ $file =~ WINEPREFIX ]] ||
					[[ $file =~ WINEESYNC ]] ||
					[[ $file =~ WINEFSYNC ]] ||
					[[ $file =~ DBUS ]] ||
					[[ $file =~ AT_SPI_BUS ]]
			then
				# handle semicolons and other weird characters in value by re-assigning
				(
					IFS='=' read -r left right <<<"$file"
					echo "export $left=\"$right\"" >>"$env_file"
				)
			fi
		done <"$process_file"
	fi
	if [[ ! -f $env_file ]]; then
		echo "Warning! Environment file not found! Missing permissions?"
	else
		echo "Loading environment cache from $env_file"
		source "$env_file"
		echo "done"
	fi
}

set_wayland_workaround() {
	#TODO: Re-enable this after adding a wine version check
	session_type=$(loginctl show-session "$(awk '/tty/ {print $1}' <(loginctl list-sessions | grep "$USER" | grep "active" -w))" -p Type | awk -F= '{print $2}')
	if [[ $session_type == "wayland" ]]; then
		#unset DISPLAY=
		# HACK: manually set WINEPREFIX
		WINEPREFIX="${_xlcore_data_folder}/wineprefix"
		export WINEPREFIX
		#build the registry file
		echo "Building wine workaround registry file"
		echo 'Windows Registry Editor Version 5.00

		[HKEY_CURRENT_USER\Software\Wine\Drivers]
		"Graphics"="x11,wayland"
		' >/tmp/wayland_graphics.reg
		echo "Loading wayland workaround"
		if [[ -f $_wine_executable ]]; then
			"$_wine_executable" start regedit.exe /tmp/wayland_graphics.reg
		fi
		# update the launcher args according to the instructions
		if grep AdditionalArgs= "$_launcher_ini" | grep DISPLAY= -w; then
			echo "All good"
		else
			if [[ $(grep -c "AdditionalArgs=" "$_launcher_ini") -eq 1 ]]; then
				echo "Please manually add 'DISPLAY=' to your launch arguments until this script is fixed"
			else
				echo 'AdditionalArgs=DISPLAY=' >>"$_launcher_ini"
			fi
		fi
	fi
}

# Optimizations and tweaks
mesa_glthread=true
export mesa_glthread

# Back up the in-prefix Penumbra folder if present, because crossing filesystems
# in wine leads to really bad stutters
if [[ -d ~/.xlcore/wineprefix/drive_c/Penumbra ]]; then
	notify-send "XIVLauncher Wrapper" "Backing up Penumbra Mods"
	rsync -a ~/.xlcore/wineprefix/drive_c/Penumbra ~/
fi
# Same for Mare Storage
#
if [[ -d ~/.xlcore/wineprefix/drive_c/MareCache ]]; then
	notify-send "XIVLauncher Wrapper" "Backing up Mare Cache"
	rsync -a ~/.xlcore/wineprefix/drive_c/MareCache ~/
fi

# init "$@"
# Brutal cleanup for now until everything works
killall -v -s9 -r xiv XIV
if [[ "$(get_systemd_session_type)" == "wayland" ]]; then
	# FIXME: use workaround instead after checking for wine version that supports it
	if [[ $(env | grep -c -w DISPLAY) == 0 ]]; then
		export DISPLAY=:0
	fi
fi
find_xlcore_bin
apply_fixups
start_xlcore
wait_for_game
load_settings_from_xlcore
clone_live_game_env
sleep 3
if [[ $START_TEAMCRAFT -eq 1 ]]; then
	if ! is_teamcraft_running; then
		~/Games/ffxivteamcraft.sh &
	fi
fi
if ! is_bridge_running; then
	~/Games/ffxiv_rpc_service
fi

