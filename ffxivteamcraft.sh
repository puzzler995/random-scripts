#!/usr/bin/env bash

_lockfile="${XDG_RUNTIME_DIR:-/tmp}/ffxiv_teamcraft.lock"
trap 'rm -f $_lockfile' EXIT
if (
    set -C
    : >"$_lockfile"
); then
    _launcher_bin=""
    _wine_executable=""
    _launcher_ini="$HOME/.xlcore/launcher.ini"
    _teamcraft_file=""

    _game_pid=""
    is_xiv_running() {
        _game_pid=$(pgrep ffxiv_dx11.exe 2>/dev/null)
        return $?
    }
    _teamcraft_pid=""
    is_teamcraft_running() {
        _teamcraft_pid=$(pgrep -f FFXIV\ Teamcraft.exe 2>/dev/null)
        return $?
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
		if [[ $wine_type == "Managed" ]]; then
			# Crude but until XLCore exposes this, it will have to do...
			wine_binary_path=$(dirname "$(find "$HOME"/.xlcore/compatibilitytool/ -type f -name wine)")
		else
			_xlcore_wine_binary_path_setting=$(grep -F WineBinaryPath "$_launcher_ini" | cut -d '=' -f 2)
			wine_binary_path="$_xlcore_wine_binary_path_setting"
		fi
		if [[ ! -d $(readlink -f "$wine_binary_path") ]]; then
			echo "Wine executable doesn't exist!!!"
			exit 1
		fi
		_wine_executable=${wine_binary_path}/wine
		echo "Wine runner: $_wine_executable"
	}

    #NOTE: Is this still needed since we read the game's environment?
	load_settings_from_xlcore() {
		# The bridge needs to run using the same wine binary and the same FSYNC/ESYNC/FUTEX2/etc parameters, otherwise it will fail, or crash.
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

    clone_live_game_env() {
		# Load the environment variables from the running process
		# FIXME: Running wine with CAP_SYS_ADMIN will require running this script
		# with the same permissions in order to read the environment file.
		process_file="/proc/${_game_pid}/environ"
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
			source "$env_file"
		fi
	}

    set_teamcraft_path() {
        _test_file="$HOME/.xlcore/wineprefix/drive_c/users/kat/AppData/Local/ffxiv-teamcraft/FFXIV Teamcraft.exe"
        if [[ -f "$_test_file" ]]; then
            echo "Found Teamcraft: '$_test_file'"
            _teamcraft_file="$_test_file"
            return
        fi
        echo "Teamcraft not found!"
        exit 1
    }

    last_game_pid=$_game_pid
    while sleep 5; do
        if is_xiv_running; then
            if [[ $last_game_pid -ne $_game_pid ]]; then
                # game process changed, kill bridge to deal with env changes
                echo "Game PID Changed; restarting service"
				last_game_pid=$_game_pid
                if is_teamcraft_running; then
                    kill -s TERM -- "$_teamcraft_pid"
                fi
            elif ! is_teamcraft_running; then
                set_teamcraft_path
                load_settings_from_xlcore
                until is_xiv_running; do sleep 1; done
                clone_live_game_env
                get_wine_binary
                if [[ -z $_wine_executable ]]; then echo "WINE EXECUTABLE NOT SET"; fi
                if [[ -z $_teamcraft_file ]]; then echo "TEAMCRAFT FILE NOT SET"; fi
                $_wine_executable "$_teamcraft_file"
                exit 0
            fi
        fi
    done
fi