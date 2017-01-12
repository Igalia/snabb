#!/usr/bin/env bash

SKIPPED_CODE=43

if [[ -z "$SNABB_PCI0" ]]; then
    echo "SNABB_PCI0 not set"
    exit $SKIPPED_CODE
fi

if [[ -z "$SNABB_PCI1" ]]; then
    echo "SNABB_PCI1 not set"
    exit $SKIPPED_CODE
fi

LWAFTR_CONF=./program/lwaftr/tests/data/no_icmp.conf
TEMP_FILE=$(mktemp)

function tmux_launch {
    command="$2 2>&1 | tee $3"
    if [ -z "$tmux_session" ]; then
        tmux_session=test_env-$$
        tmux new-session -d -n "$1" -s $tmux_session "$command"
    else
        tmux new-window -a -d -n "$1" -t $tmux_session "$command"
    fi
}

function kill_lwaftr {
    ps aux | grep $SNABB_PCI0 | awk '{print $2}' | xargs kill 2>/dev/null
}

function cleanup {
    kill_lwaftr
    rm -f $TEMP_FILE
    exit
}

trap cleanup EXIT HUP INT QUIT TERM

function get_lwaftr_follower {
    local leaders=$(ps aux | grep "\-\-reconfigurable" | grep $SNABB_PCI0 | grep -v "grep" | awk '{print $2}')
    for pid in $(ls /var/run/snabb); do
        for leader in ${leaders[@]}; do
            if [[ -L "/var/run/snabb/$pid/group" ]]; then
                local target=$(ls -l /var/run/snabb/$pid/group | awk '{print $11}' | grep -oe "[0-9]\+")
                if [[ "$leader" == "$target" ]]; then
                    echo $pid
                fi
            fi
        done
    done
}

function fatal {
    local msg=$1
    echo "Error: $msg"
    exit 1
}

function test_lwaftr_query {
    ./snabb lwaftr query $@ > $TEMP_FILE
    local lineno=`cat $TEMP_FILE | wc -l`
    if [[ $lineno -gt 1 ]]; then
        echo "Success: lwaftr query $@"
    else
        fatal "lwaftr query $@"
    fi
}

# Run lwAFTR.
tmux_launch "lwaftr" "./snabb lwaftr run --reconfigurable --name lwaftr --conf $LWAFTR_CONF --v4 $SNABB_PCI0 --v6 $SNABB_PCI1" "lwaftr.log"
sleep 2

# Test query all.
test_lwaftr_query -l

# Test query by pid.
pid=$(get_lwaftr_follower)
if [[ -n "$pid" ]]; then
    test_lwaftr_query $pid
    test_lwaftr_query $pid "memuse-ipv"
fi

# Test query by name.
test_lwaftr_query "--name lwaftr"
test_lwaftr_query "--name lwaftr memuse-ipv"
