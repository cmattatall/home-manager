

# Export the PRESET environment variable to the current shell
cme(){
    local _preset=$1

    # Detect the CMakePresets.json file
    local presets_file="CMakePresets.json"
    if [ ! -f "$presets_file" ]; then
        echo "Error: $presets_file not found in current directory: $PWD"
        return 1
    fi

    preset_names=$(cmake --list-presets=build | tail -n +3 | tr -d '"' | sort)
    declare -A preset_map=()

    # The following generates a lookup table of index:name from the preset_names list
    # Outputs the list of indexed presets for user selection (e.g.: 1:foo, 2:bar, ...)
    local i=0
    for name in ${preset_names}; do
        preset_map[$i]="$name"
        ((i++))
    done

    # If caller provide an input to export, check if valid and export
    if [ ! -z "$_preset" ]; then
        # Check if $_preset is valid
        local valid=false
        for idx in "${!preset_map[@]}"; do
            if [[ "${preset_map[$idx]}" == "$_preset" ]]; then
                valid=true
                break
            fi
        done
        if [ "$valid" != "true" ]; then
            echo "Error: '$_preset' is not a valid CMake _preset"
            return 1
        fi
        export PRESET="$_preset"
        return 0
    fi

    echo -en "Select a _preset:\n"
    for idx in $(printf '%s\n' "${!preset_map[@]}" | sort -n); do
        echo "[$idx] ${preset_map[$idx]}"
    done
    read selection < /dev/stdin

    # Strip leading and trailing whitespace
    selection=$(echo "$selection" | tr -d '[:space:]')

    # If user entered a number look up the _preset name by that number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local idx=$((selection))
        _preset="${preset_map[$idx]}"
    else
        _preset="$selection"
        # Make sure it's a valid _preset
        if [[ -z "${preset_map[@]}" ]] || [[ -z "$_preset" ]] || ! printf '%s\0' "${preset_map[@]}" | grep -Fxqz -- "$_preset"; then
            echo "Error: '$_preset' is not a valid CMake _preset"
            return 1
        fi
    fi
    echo "Setting PRESET to $_preset"
    export PRESET="$_preset"
    return 0
}


cmc(){
    if [ -z "$PRESET" ]; then
        echo "PRESET is not set"
        cme
    fi
    cmake --preset $PRESET $@
}

cmb(){
    if [ -z "$PRESET" ]; then
        echo "Error: PRESET is not set"
        return 1
    fi
    cmake --build --preset $PRESET -j8 $@
}
