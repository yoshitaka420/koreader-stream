#!/bin/sh

RestoreWifi() {
    echo "[$(date)] restore-wifi-async.sh: Restarting Wi-Fi"

    ./enable-wifi.sh

    # Much like we do in the UI, ensure wpa_supplicant did its job properly, first.
    # Pilfered from https://github.com/shermp/Kobo-UNCaGED/pull/21 ;)
    wpac_elapsed_us=0
    wpac_timeout_us=15000000
    wpac_wait_us=250000
    while ! wpa_cli status | grep -q "wpa_state=COMPLETED"; do
        # If wpa_supplicant hasn't connected within 15 seconds, assume it never will, and tear down Wi-Fi
        if [ "${wpac_elapsed_us}" -ge "${wpac_timeout_us}" ]; then
            echo "[$(date)] restore-wifi-async.sh: Failed to connect to preferred AP!"
            ./disable-wifi.sh
            return 1
        fi

        # Association takes seconds on Kobo hardware. Exponential backoff keeps
        # the first status update responsive without waking the CPU and running
        # wpa_cli sixty times on a failed restore.
        wpac_remaining_us=$((wpac_timeout_us - wpac_elapsed_us))
        if [ "${wpac_wait_us}" -gt "${wpac_remaining_us}" ]; then
            wpac_wait_us=${wpac_remaining_us}
        fi
        usleep "${wpac_wait_us}"
        wpac_elapsed_us=$((wpac_elapsed_us + wpac_wait_us))
        if [ "${wpac_wait_us}" -lt 2000000 ]; then
            wpac_wait_us=$((wpac_wait_us * 2))
            if [ "${wpac_wait_us}" -gt 2000000 ]; then
                wpac_wait_us=2000000
            fi
        fi
    done

    ./obtain-ip.sh

    echo "[$(date)] restore-wifi-async.sh: Restarted Wi-Fi"
}

RestoreWifi &
