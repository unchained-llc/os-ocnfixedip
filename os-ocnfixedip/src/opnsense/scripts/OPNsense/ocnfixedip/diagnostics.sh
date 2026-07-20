#!/bin/sh

# OCN Fixed IP (IPoE) diagnostics script
# Endpoint checks:
# - tunnel state / route / alias
# - DNS / IPv4 / IPv6 / CE->BR reachability
# - MTU checks
# - Prefix update API check

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

resolve_name="one.one.one.one"
resolve_a_status="untested"
resolve_a_answer="-"
resolve_aaaa_status="untested"
resolve_aaaa_answer="-"

curl_target="https://one.one.one.one/"
curl_v4_source="-"
curl_v4_status="untested"
curl_v4_http_code="-"
curl_v4_remote_ip="-"
curl_v4_ssl_verify_result="-"
curl_v6_source="-"
curl_v6_status="untested"
curl_v6_http_code="-"
curl_v6_remote_ip="-"
curl_v6_ssl_verify_result="-"

inet_target="1.1.1.1"
inet_source="-"
inet_status="untested"
inet_rtt="-"

ipv6_target="2606:4700:4700::1111"
ipv6_source="-"
ipv6_status="untested"
ipv6_rtt="-"

ce_source=""
br_target=""
ce_to_br_status="untested"
ce_to_br_rtt="-"

wan_alias_if="-"
wan_alias_status="untested"

prefix_update_target="-"
prefix_update_status="untested"
prefix_update_result="-"

tunnel_state_status="untested"
tunnel_state_detail="gif0 not checked"

route_target="192.0.0.1"
route_gateway="-"
route_iface="-"
route_status="untested"

mtu_expected="${MTU:-1460}"
mtu_actual="-"
mtu_status="untested"

mtu_probe_target="1.1.1.1"
mtu_probe_payload="-"
mtu_probe_status="untested"
mtu_probe_rtt="-"

mtu_frag_target="1.1.1.1"
mtu_frag_payload="-"
mtu_frag_status="untested"
mtu_frag_rtt="-"

mtu6_probe_target="2606:4700:4700::1111"
mtu6_probe_source="-"
mtu6_probe_payload="-"
mtu6_probe_status="untested"
mtu6_probe_rtt="-"

mtu6_frag_target="2606:4700:4700::1111"
mtu6_frag_source="-"
mtu6_frag_payload="-"
mtu6_frag_status="untested"
mtu6_frag_rtt="-"

if command -v drill >/dev/null 2>&1; then
    resolve_a_answer=$(drill "${resolve_name}" A 2>/dev/null | awk '/\tIN\tA\t/ {print $5; exit}')
    resolve_aaaa_answer=$(drill "${resolve_name}" AAAA 2>/dev/null | awk '/\tIN\tAAAA\t/ {print $5; exit}')
elif command -v host >/dev/null 2>&1; then
    resolve_a_answer=$(host -t A "${resolve_name}" 2>/dev/null | awk '/has address/ {print $NF; exit}')
    resolve_aaaa_answer=$(host -t AAAA "${resolve_name}" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')
elif command -v getent >/dev/null 2>&1; then
    resolve_a_answer=$(getent hosts "${resolve_name}" 2>/dev/null | awk '$1 !~ /:/ {print $1; exit}')
    resolve_aaaa_answer=$(getent hosts "${resolve_name}" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
else
    resolve_a_status="skipped"
    resolve_aaaa_status="skipped"
fi

if [ "${resolve_a_status}" != "skipped" ]; then
    if [ -n "${resolve_a_answer}" ]; then
        resolve_a_status="ok"
    else
        resolve_a_status="ng"
        resolve_a_answer="-"
    fi
fi

if [ "${resolve_aaaa_status}" != "skipped" ]; then
    if [ -n "${resolve_aaaa_answer}" ]; then
        resolve_aaaa_status="ok"
    else
        resolve_aaaa_status="ng"
        resolve_aaaa_answer="-"
    fi
fi





if tunnel_exists; then
    ifdata=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    tunnel_ipv4=$(printf '%s' "${ifdata}" | awk '/inet / {print $2; exit}')
    mtu_actual=$(printf '%s' "${ifdata}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)

    if printf '%s' "${ifdata}" | grep -q "UP" && printf '%s' "${ifdata}" | grep -q "RUNNING"; then
        tunnel_state_status="ok"
        tunnel_state_detail="${TUNNEL_IF} is UP/RUNNING"
    else
        tunnel_state_status="ng"
        tunnel_state_detail="${TUNNEL_IF} is not RUNNING"
    fi

    if [ -n "${mtu_actual}" ] && [ "${mtu_actual}" = "${mtu_expected}" ]; then
        mtu_status="ok"
    elif [ -n "${mtu_actual}" ]; then
        mtu_status="ng"
    else
        mtu_status="ng"
        mtu_actual="-"
    fi

    remote_v6=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {print $5; exit}')
    local_v6=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {print $3; exit}')

    br_target="${FIXEDIP_AFTR:-${remote_v6}}"
    ce_source="${local_v6}"
    if [ -z "${ce_source}" ] && [ -f /var/run/ocnfixedip_local_tunnel_v6 ]; then
        ce_source=$(cat /var/run/ocnfixedip_local_tunnel_v6 2>/dev/null)
    fi

    # WAN /128 alias presence check
    wan_alias_if=$(get_wan_if_device)
    if [ -n "${ce_source}" ] && [ -n "${wan_alias_if}" ] && ifconfig "${wan_alias_if}" >/dev/null 2>&1; then
        if ifconfig "${wan_alias_if}" 2>/dev/null | awk '/inet6 / {gsub(/%.*/, "", $2); print $2}' | grep -qx "${ce_source}"; then
            wan_alias_status="ok"
        else
            wan_alias_status="ng"
        fi
    else
        wan_alias_status="skipped"
    fi

    if [ -n "${tunnel_ipv4}" ]; then
        inet_source="${tunnel_ipv4}"

        inet_ping_out=$(ping -c 1 -W 2 -S "${tunnel_ipv4}" "${inet_target}" 2>&1)
        if [ $? -eq 0 ]; then
            inet_status="ok"
            inet_rtt=$(printf '%s' "${inet_ping_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${inet_rtt}" ] || inet_rtt="-"
        else
            inet_status="ng"
        fi

        curl_v4_source="${tunnel_ipv4}"
        if command -v curl >/dev/null 2>&1; then
            curl_v4_metrics=$(curl -4 -sS -o /dev/null -w '%{http_code}|%{ssl_verify_result}|%{remote_ip}' --connect-timeout 2 --max-time 5 --interface "${tunnel_ipv4}" "${curl_target}" 2>/dev/null)
            curl_v4_rc=$?
            curl_v4_http_code=$(printf '%s' "${curl_v4_metrics}" | awk -F'|' '{print $1}')
            curl_v4_ssl_verify_result=$(printf '%s' "${curl_v4_metrics}" | awk -F'|' '{print $2}')
            curl_v4_remote_ip=$(printf '%s' "${curl_v4_metrics}" | awk -F'|' '{print $3}')
            [ -n "${curl_v4_remote_ip}" ] || curl_v4_remote_ip="-"
            [ -n "${curl_v4_ssl_verify_result}" ] || curl_v4_ssl_verify_result="-"

            if [ ${curl_v4_rc} -eq 0 ] && [ -n "${curl_v4_http_code}" ] && [ "${curl_v4_http_code}" != "000" ]; then
                curl_v4_status="ok"
            else
                curl_v4_status="ng"
                [ -n "${curl_v4_http_code}" ] || curl_v4_http_code="-"
            fi
        else
            curl_v4_status="skipped"
        fi

        if [ -n "${mtu_actual}" ] && [ "${mtu_actual}" -ge 1280 ] 2>/dev/null; then
            mtu_probe_payload=$(( mtu_actual - 28 ))
            if [ "${mtu_probe_payload}" -gt 0 ] 2>/dev/null; then
                mtu_probe_out=$(ping -D -c 1 -W 2 -S "${tunnel_ipv4}" -s "${mtu_probe_payload}" "${mtu_probe_target}" 2>&1)
                if [ $? -eq 0 ]; then
                    mtu_probe_status="ok"
                    mtu_probe_rtt=$(printf '%s' "${mtu_probe_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                    [ -n "${mtu_probe_rtt}" ] || mtu_probe_rtt="-"
                else
                    mtu_probe_status="ng"
                fi
            else
                mtu_probe_status="skipped"
            fi

            mtu_frag_payload=$(( mtu_actual + 100 - 28 ))
            if [ "${mtu_frag_payload}" -gt 0 ] 2>/dev/null; then
                mtu_frag_out=$(ping -c 1 -W 2 -S "${tunnel_ipv4}" -s "${mtu_frag_payload}" "${mtu_frag_target}" 2>&1)
                if [ $? -eq 0 ]; then
                    mtu_frag_status="ok"
                    mtu_frag_rtt=$(printf '%s' "${mtu_frag_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                    [ -n "${mtu_frag_rtt}" ] || mtu_frag_rtt="-"
                else
                    mtu_frag_status="ng"
                fi
            else
                mtu_frag_status="skipped"
            fi
        else
            mtu_probe_status="skipped"
            mtu_frag_status="skipped"
        fi
    else
        inet_status="skipped"
        curl_v4_status="skipped"
        mtu_probe_status="skipped"
        mtu_frag_status="skipped"
    fi

    # CE -> BR check
    if [ -n "${ce_source}" ] && [ -n "${br_target}" ]; then
        ce_br_ping_out=$(ping -6 -c 1 -W 2 -S "${ce_source}" "${br_target}" 2>&1)
        if [ $? -eq 0 ]; then
            ce_to_br_status="ok"
            ce_to_br_rtt=$(printf '%s' "${ce_br_ping_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${ce_to_br_rtt}" ] || ce_to_br_rtt="-"
        else
            ce_to_br_status="ng"
        fi
    elif [ -z "${br_target}" ]; then
        ce_to_br_status="not-configured"
    else
        ce_to_br_status="skipped"
    fi

    # IPv6 internet check from CE source
    if [ -n "${ce_source}" ]; then
        ipv6_source="${ce_source}"
        curl_v6_source="${ce_source}"
        mtu6_probe_source="${ce_source}"
        mtu6_frag_source="${ce_source}"

        ipv6_ping_out=$(ping -6 -c 1 -W 2 -S "${ce_source}" "${ipv6_target}" 2>&1)
        if [ $? -eq 0 ]; then
            ipv6_status="ok"
            ipv6_rtt=$(printf '%s' "${ipv6_ping_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${ipv6_rtt}" ] || ipv6_rtt="-"
        else
            ipv6_status="ng"
        fi

        if [ -n "${mtu_actual}" ] && [ "${mtu_actual}" -ge 1280 ] 2>/dev/null; then
            mtu6_probe_payload=$(( mtu_actual - 48 ))
            if [ "${mtu6_probe_payload}" -gt 0 ] 2>/dev/null; then
                mtu6_probe_out=$(ping -6 -D -c 1 -W 2 -S "${ce_source}" -s "${mtu6_probe_payload}" "${mtu6_probe_target}" 2>&1)
                if [ $? -eq 0 ]; then
                    mtu6_probe_status="ok"
                    mtu6_probe_rtt=$(printf '%s' "${mtu6_probe_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                    [ -n "${mtu6_probe_rtt}" ] || mtu6_probe_rtt="-"
                else
                    mtu6_probe_status="ng"
                fi
            else
                mtu6_probe_status="skipped"
            fi

            mtu6_frag_payload=$(( mtu_actual + 100 - 48 ))
            if [ "${mtu6_frag_payload}" -gt 0 ] 2>/dev/null; then
                mtu6_frag_out=$(ping -6 -c 1 -W 2 -S "${ce_source}" -s "${mtu6_frag_payload}" "${mtu6_frag_target}" 2>&1)
                if [ $? -eq 0 ]; then
                    mtu6_frag_status="ok"
                    mtu6_frag_rtt=$(printf '%s' "${mtu6_frag_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                    [ -n "${mtu6_frag_rtt}" ] || mtu6_frag_rtt="-"
                else
                    mtu6_frag_status="ng"
                fi
            else
                mtu6_frag_status="skipped"
            fi
        else
            mtu6_probe_status="skipped"
            mtu6_frag_status="skipped"
        fi

        if command -v curl >/dev/null 2>&1; then
            curl_v6_metrics=$(curl -6 -sS -o /dev/null -w '%{http_code}|%{ssl_verify_result}|%{remote_ip}' --connect-timeout 2 --max-time 5 --interface "${ce_source}" "${curl_target}" 2>/dev/null)
            curl_v6_rc=$?
            curl_v6_http_code=$(printf '%s' "${curl_v6_metrics}" | awk -F'|' '{print $1}')
            curl_v6_ssl_verify_result=$(printf '%s' "${curl_v6_metrics}" | awk -F'|' '{print $2}')
            curl_v6_remote_ip=$(printf '%s' "${curl_v6_metrics}" | awk -F'|' '{print $3}')
            [ -n "${curl_v6_remote_ip}" ] || curl_v6_remote_ip="-"
            [ -n "${curl_v6_ssl_verify_result}" ] || curl_v6_ssl_verify_result="-"

            if [ ${curl_v6_rc} -eq 0 ] && [ -n "${curl_v6_http_code}" ] && [ "${curl_v6_http_code}" != "000" ]; then
                curl_v6_status="ok"
            else
                curl_v6_status="ng"
                [ -n "${curl_v6_http_code}" ] || curl_v6_http_code="-"
            fi
        else
            curl_v6_status="skipped"
        fi
    else
        ipv6_status="skipped"
        mtu6_probe_status="skipped"
        mtu6_frag_status="skipped"
        curl_v6_status="skipped"
    fi
else
    tunnel_state_status="skipped"
    tunnel_state_detail="${TUNNEL_IF} does not exist"
    wan_alias_status="skipped"
    mtu_status="skipped"
    inet_status="skipped"
    curl_v4_status="skipped"
    mtu_probe_status="skipped"
    mtu_frag_status="skipped"
    ce_to_br_status="skipped"
    ipv6_status="skipped"
    mtu6_probe_status="skipped"
    mtu6_frag_status="skipped"
    curl_v6_status="skipped"
fi

route_info=$(route -n get default 2>/dev/null)
if [ -n "${route_info}" ]; then
    route_gateway=$(printf '%s' "${route_info}" | awk -F': ' '/gateway:/ {print $2; exit}')
    route_iface=$(printf '%s' "${route_info}" | awk -F': ' '/interface:/ {print $2; exit}')

    if [ "${route_gateway}" = "${route_target}" ] && [ "${route_iface}" = "${TUNNEL_IF}" ]; then
        route_status="ok"
    else
        route_status="ng"
    fi
else
    route_status="ng"
fi



# Prefix update API check (live call)
if [ -n "${FIXEDIP_UPDATE_URL}" ] && [ -n "${FIXEDIP_AUTH_USER}" ]; then
    prefix_update_target="${FIXEDIP_UPDATE_URL}"
    if [ -n "${FIXEDIP_UPDATE_HOSTNAME}" ] && ! printf '%s' "${prefix_update_target}" | grep -q 'hostname='; then
        case "${prefix_update_target}" in
            *\?*) prefix_update_target="${prefix_update_target}&hostname=${FIXEDIP_UPDATE_HOSTNAME}" ;;
            *) prefix_update_target="${prefix_update_target}?hostname=${FIXEDIP_UPDATE_HOSTNAME}" ;;
        esac
    fi

    NETRC=$(mktemp /tmp/ocnfixedip-diag-netrc.XXXXXX)
    chmod 600 "${NETRC}"
    printf "default\nlogin %s\npassword %s\n" "${FIXEDIP_AUTH_USER}" "${FIXEDIP_AUTH_PASS}" > "${NETRC}"
    prefix_update_out=$(curl -6 -sk --connect-timeout 2 --netrc-file "${NETRC}" "${prefix_update_target}" 2>&1)
    curl_rc=$?
    rm -f "${NETRC}"

    if [ ${curl_rc} -eq 0 ]; then
        prefix_update_result=$(printf '%s' "${prefix_update_out}" | awk '{print $1; exit}')
        case "${prefix_update_result}" in
            good|nochg) prefix_update_status="ok" ;;
            nohost|badauth|notfqdn|abuse) prefix_update_status="ng" ;;
            *)
                if [ -n "${prefix_update_result}" ]; then
                    prefix_update_status="ng"
                else
                    prefix_update_status="ng"
                    prefix_update_result="-"
                fi
                ;;
        esac
    else
        prefix_update_status="ng"
        prefix_update_result="curl-error"
    fi

    # keep status.sh and widget health in sync with latest diagnostics result
    if [ "${prefix_update_status}" = "ok" ]; then
        printf '%s %s %s\n' "$(date +%s)" "0" "${prefix_update_result}" > /var/run/ocnfixedip_prefix_update_status
    else
        printf '%s %s %s\n' "$(date +%s)" "1" "${prefix_update_result}" > /var/run/ocnfixedip_prefix_update_status
    fi
else
    prefix_update_status="not-configured"
fi

printf '{"checks":{"tunnel_state":{"status":"%s","detail":"%s"},"default_route":{"target":"%s","gateway":"%s","interface":"%s","status":"%s"},"wan_alias":{"interface":"%s","source":"%s","status":"%s"},"ce_to_br":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"prefix_update":{"target":"%s","status":"%s","result":"%s"},"internet":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"ipv6_internet":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"resolve_a":{"target":"%s","status":"%s","answer":"%s"},"resolve_aaaa":{"target":"%s","status":"%s","answer":"%s"},"mtu":{"expected":"%s","actual":"%s","status":"%s"},"mtu_probe":{"source":"%s","target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"},"mtu_fragmentation":{"source":"%s","target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"},"mtu6_probe":{"source":"%s","target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"},"mtu6_fragmentation":{"source":"%s","target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"},"curl_v4":{"source":"%s","target":"%s","status":"%s","http_code":"%s","remote_ip":"%s","ssl_verify_result":"%s"},"curl_v6":{"source":"%s","target":"%s","status":"%s","http_code":"%s","remote_ip":"%s","ssl_verify_result":"%s"}}}' \
    "${tunnel_state_status}" "${tunnel_state_detail}" "${route_target}" "${route_gateway}" "${route_iface}" "${route_status}" "${wan_alias_if}" "${ce_source}" "${wan_alias_status}" "${ce_source}" "${br_target}" "${ce_to_br_status}" "${ce_to_br_rtt}" "${prefix_update_target}" "${prefix_update_status}" "${prefix_update_result}" "${inet_source}" "${inet_target}" "${inet_status}" "${inet_rtt}" "${ipv6_source}" "${ipv6_target}" "${ipv6_status}" "${ipv6_rtt}" "${resolve_name}" "${resolve_a_status}" "${resolve_a_answer}" "${resolve_name}" "${resolve_aaaa_status}" "${resolve_aaaa_answer}" "${mtu_expected}" "${mtu_actual}" "${mtu_status}" "${inet_source}" "${mtu_probe_target}" "${mtu_probe_payload}" "${mtu_probe_status}" "${mtu_probe_rtt}" "${inet_source}" "${mtu_frag_target}" "${mtu_frag_payload}" "${mtu_frag_status}" "${mtu_frag_rtt}" "${mtu6_probe_source}" "${mtu6_probe_target}" "${mtu6_probe_payload}" "${mtu6_probe_status}" "${mtu6_probe_rtt}" "${mtu6_frag_source}" "${mtu6_frag_target}" "${mtu6_frag_payload}" "${mtu6_frag_status}" "${mtu6_frag_rtt}" "${curl_v4_source}" "${curl_target}" "${curl_v4_status}" "${curl_v4_http_code}" "${curl_v4_remote_ip}" "${curl_v4_ssl_verify_result}" "${curl_v6_source}" "${curl_target}" "${curl_v6_status}" "${curl_v6_http_code}" "${curl_v6_remote_ip}" "${curl_v6_ssl_verify_result}"
