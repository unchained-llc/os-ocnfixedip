{#
 # Copyright (C) 2024 OCN Fixed IP (IPoE) Plugin Contributors
 # All rights reserved.
 #}

<style>
    .ocn-diag-summary {
        padding: 12px;
        margin-bottom: 12px;
        border: 1px solid #d9d9d9;
        border-left-width: 4px;
        border-radius: 4px;
        background: #fafafa;
    }

    .ocn-diag-summary.ok {
        border-left-color: #5cb85c;
    }

    .ocn-diag-summary.ng {
        border-left-color: #d9534f;
    }

    .ocn-diag-summary-title {
        font-size: 16px;
        font-weight: 700;
        line-height: 1.3;
    }

    .ocn-diag-summary-message {
        margin-top: 4px;
    }

    .ocn-diag-summary-hints {
        margin: 8px 0 0 18px;
    }

    .ocn-checks {
        border-top: 1px solid #e5e5e5;
        border-bottom: 1px solid #e5e5e5;
        padding: 6px 0;
    }

    .ocn-check-row {
        padding: 6px 0;
    }

    .ocn-check-row + .ocn-check-row {
        border-top: 1px dashed #ececec;
    }

    .ocn-check-title {
        font-size: 14px;
        line-height: 1.2;
    }

    .ocn-check-title strong {
        font-size: 16px;
    }

    .ocn-check-detail {
        margin-top: 4px;
        color: #666;
    }

    .ocn-check-title .label {
        margin-right: 6px;
    }


</style>

<script>
    $(document).ready(function() {
        function badge(status) {
            if (status === 'ok') {
                return '<i class="fa fa-check-circle text-success"></i> <span class="label label-success">OK</span>';
            }
            if (status === 'ng') {
                return '<i class="fa fa-times-circle text-danger"></i> <span class="label label-danger">NG</span>';
            }
            if (status === 'not-configured') {
                return '<i class="fa fa-exclamation-circle text-warning"></i> <span class="label label-warning">NOT CONFIGURED</span>';
            }
            if (status === 'skipped') {
                return '<i class="fa fa-minus-circle text-muted"></i> <span class="label label-default">SKIPPED</span>';
            }
            return '<i class="fa fa-circle text-muted"></i> <span class="label label-default">UNTESTED</span>';
        }

        function line(title, detail, status, tail) {
            return '<div class="ocn-check-row">' +
                   '<div class="ocn-check-title">' + badge(status) + '<strong>' + title + '</strong></div>' +
                   '<div class="ocn-check-detail">' + detail + (tail || '') + '</div>' +
                   '</div>';
        }

        function checkTitle(key) {
            var map = {
                tunnel_state: 'Tunnel state',
                default_route: 'IPv4 default route to tunnel',
                wan_alias: 'WAN /128 alias present',
                ce_to_br: 'IPv6 CE-to-BR Ping',
                prefix_update: 'Prefix update API check',
                internet: 'IPv4 internet Ping 1.1.1.1',
                ipv6_internet: 'IPv6 internet Ping 2606:4700:4700::1111',
                resolve_a: 'DNS A name resolution',
                resolve_aaaa: 'DNS AAAA name resolution',
                curl_v4: 'IPv4 curl one.one.one.one',
                curl_v6: 'IPv6 curl one.one.one.one',
                mtu: 'Tunnel MTU config',
                mtu_probe: 'IPv4 MTU probe (DF Ping)',
                mtu_fragmentation: 'IPv4 large packet fragmentation test',
                mtu6_probe: 'IPv6 MTU probe (DF Ping)',
                mtu6_fragmentation: 'IPv6 large packet fragmentation test'
            };
            return map[key] || key;
        }

        function troubleshootingHint(key) {
            var map = {
                tunnel_state: 'Re-apply the service and confirm gif0 becomes UP/RUNNING.',
                default_route: 'Confirm the IPv4 default route is 192.0.0.1 via gif0.',
                wan_alias: 'Confirm the WAN has the local tunnel IPv6 /128 alias.',
                ce_to_br: 'Check the BR endpoint, CE source, and IPv6 reachability (including filtering).',
                prefix_update: 'Check update URL/hostname/credentials and OCN response (good/nochg).',
                internet: 'Verify 1.1.1.1 is reachable with tunnel IPv4 source and check NAT/routes.',
                ipv6_internet: 'Verify external IPv6 reachability from CE source (2606:4700:4700::1111).',
                resolve_a: 'Check DNS server settings and A-record lookup for one.one.one.one.',
                resolve_aaaa: 'Check DNS server settings and AAAA-record lookup for one.one.one.one.',
                curl_v4: 'Check IPv4 egress path and source binding, then retry curl -4 to one.one.one.one.',
                curl_v6: 'Check IPv6 egress path and source binding, then retry curl -6 to one.one.one.one.',
                mtu: 'Confirm configured MTU matches the runtime gif0 MTU.',
                mtu_probe: 'Confirm DF ping (IPv4 total=MTU) succeeds; adjust MSS/path MTU if needed.',
                mtu_fragmentation: 'Confirm large IPv4 packets (DF off) are fragmented and forwarded properly.',
                mtu6_probe: 'Confirm IPv6 DF ping (IPv6 total=MTU) succeeds from CE source.',
                mtu6_fragmentation: 'Confirm large IPv6 packets are fragmented at source and forwarded properly.'
            };
            return map[key] || 'Check configuration and routing.';
        }

        function renderSummary(checks) {
            var requiredOrder = [
                'tunnel_state',
                'default_route',
                'wan_alias',
                'mtu',
                'ce_to_br',
                'prefix_update',
                'internet',
                'ipv6_internet',
                'mtu_probe',
                'mtu6_probe',
                'mtu_fragmentation',
                'mtu6_fragmentation',
                'resolve_a',
                'curl_v4',
                'resolve_aaaa',
                'curl_v6'
            ];

            var passed = 0;
            var failed = [];
            for (var i = 0; i < requiredOrder.length; i++) {
                var key = requiredOrder[i];
                var st = (checks[key] && checks[key].status) ? checks[key].status : null;
                if (st === 'ok') {
                    passed++;
                } else {
                    failed.push(key);
                }
            }

            var total = requiredOrder.length;
            var html = '';

            if (passed === total) {
                html = '<div class="ocn-diag-summary ok">' +
                       '<div class="ocn-diag-summary-title"><i class="fa fa-check-circle text-success"></i> Summary: ' + passed + '/' + total + ' checks passed</div>' +
                       '<div class="ocn-diag-summary-message">Congratulations! Enjoy your high-speed internet connection!</div>' +
                       '</div>';
            } else {
                var hintItems = '';
                for (var j = 0; j < failed.length; j++) {
                    var fkey = failed[j];
                    hintItems += '<li><strong>' + checkTitle(fkey) + ':</strong> ' + troubleshootingHint(fkey) + '</li>';
                }

                html = '<div class="ocn-diag-summary ng">' +
                       '<div class="ocn-diag-summary-title"><i class="fa fa-exclamation-triangle text-danger"></i> Summary: ' + passed + '/' + total + ' checks passed</div>' +
                       '<div class="ocn-diag-summary-message">Some checks are failing. Please review these quick troubleshooting tips:</div>' +
                       '<ul class="ocn-diag-summary-hints">' + hintItems + '</ul>' +
                       '</div>';
            }

            $('#diag_summary').html(html);
        }

        function renderChecks(data) {
            if (!data || !data.checks) {
                $('#diag_summary').html('<div class="ocn-diag-summary ng"><div class="ocn-diag-summary-title">Summary: 0/0 checks passed</div><div class="ocn-diag-summary-message">No diagnostics data returned.</div></div>');
                $('#diag_checks').html('<div class="text-danger">No diagnostics data returned.</div>');
                return;
            }

            var checks = data.checks;
            renderSummary(checks);

            var html = '';

            var tunnelDetail = (checks.tunnel_state && checks.tunnel_state.detail) ? checks.tunnel_state.detail : 'gif0 not checked';
            html += line('Tunnel state', tunnelDetail, checks.tunnel_state ? checks.tunnel_state.status : null, '');

            var routeTarget = (checks.default_route && checks.default_route.target) ? checks.default_route.target : '192.0.0.1';
            var routeGw = (checks.default_route && checks.default_route.gateway) ? checks.default_route.gateway : '-';
            var routeIf = (checks.default_route && checks.default_route.interface) ? checks.default_route.interface : '-';
            html += line('IPv4 default route to tunnel', 'expect: ' + routeTarget + ' via gif0, actual: ' + routeGw + ' via ' + routeIf, checks.default_route ? checks.default_route.status : null, '');

            var wanAliasIf = (checks.wan_alias && checks.wan_alias.interface) ? checks.wan_alias.interface : '-';
            var wanAliasSrc = (checks.wan_alias && checks.wan_alias.source) ? checks.wan_alias.source : '-';
            html += line('WAN /128 alias present', 'interface: ' + wanAliasIf + ', source: ' + wanAliasSrc, checks.wan_alias ? checks.wan_alias.status : null, '');

            var mtuExpected = (checks.mtu && checks.mtu.expected) ? checks.mtu.expected : '-';
            var mtuActual = (checks.mtu && checks.mtu.actual) ? checks.mtu.actual : '-';
            html += line('Tunnel MTU config', 'expected: ' + mtuExpected + ', actual: ' + mtuActual, checks.mtu ? checks.mtu.status : null, '');

            var ceSource = (checks.ce_to_br && checks.ce_to_br.source) ? checks.ce_to_br.source : '-';
            var brTarget = (checks.ce_to_br && checks.ce_to_br.target) ? checks.ce_to_br.target : '-';
            var ceBrRtt = (checks.ce_to_br && checks.ce_to_br.rtt_ms && checks.ce_to_br.rtt_ms !== '-') ? (' (' + checks.ce_to_br.rtt_ms + ' ms)') : '';
            html += line('IPv6 CE-to-BR Ping', 'source: ' + ceSource + ' -> target: ' + brTarget, checks.ce_to_br ? checks.ce_to_br.status : null, ceBrRtt);

            var puTarget = (checks.prefix_update && checks.prefix_update.target) ? checks.prefix_update.target : '-';
            var puResult = (checks.prefix_update && checks.prefix_update.result && checks.prefix_update.result !== '-') ? (' -> ' + checks.prefix_update.result) : '';
            html += line('Prefix update API check', puTarget, checks.prefix_update ? checks.prefix_update.status : null, puResult);

            var inetSource = (checks.internet && checks.internet.source) ? checks.internet.source : '-';
            var inetTarget = (checks.internet && checks.internet.target) ? checks.internet.target : '1.1.1.1';
            var inetRtt = (checks.internet && checks.internet.rtt_ms && checks.internet.rtt_ms !== '-') ? (' (' + checks.internet.rtt_ms + ' ms)') : '';
            html += line('IPv4 internet Ping 1.1.1.1', 'source: ' + inetSource + ' -> target: ' + inetTarget, checks.internet ? checks.internet.status : null, inetRtt);

            var ipv6Source = (checks.ipv6_internet && checks.ipv6_internet.source) ? checks.ipv6_internet.source : '-';
            var ipv6Target = (checks.ipv6_internet && checks.ipv6_internet.target) ? checks.ipv6_internet.target : '2606:4700:4700::1111';
            var ipv6Rtt = (checks.ipv6_internet && checks.ipv6_internet.rtt_ms && checks.ipv6_internet.rtt_ms !== '-') ? (' (' + checks.ipv6_internet.rtt_ms + ' ms)') : '';
            html += line('IPv6 internet Ping 2606:4700:4700::1111', 'source: ' + ipv6Source + ' -> target: ' + ipv6Target, checks.ipv6_internet ? checks.ipv6_internet.status : null, ipv6Rtt);

            var mtuProbeSource = (checks.mtu_probe && checks.mtu_probe.source) ? checks.mtu_probe.source : '-';
            var mtuProbeTarget = (checks.mtu_probe && checks.mtu_probe.target) ? checks.mtu_probe.target : '1.1.1.1';
            var mtuProbePayload = (checks.mtu_probe && checks.mtu_probe.payload) ? checks.mtu_probe.payload : '-';
            var mtuProbeIpTotal = '-';
            if (mtuProbePayload !== '-' && !isNaN(parseInt(mtuProbePayload, 10))) {
                mtuProbeIpTotal = String(parseInt(mtuProbePayload, 10) + 28);
            }
            var mtuProbeRtt = (checks.mtu_probe && checks.mtu_probe.rtt_ms && checks.mtu_probe.rtt_ms !== '-') ? (' (' + checks.mtu_probe.rtt_ms + ' ms)') : '';
            html += line('IPv4 MTU probe (DF Ping)', 'source: ' + mtuProbeSource + ' -> target: ' + mtuProbeTarget + ', payload: ' + mtuProbePayload + ' bytes (IP total: ' + mtuProbeIpTotal + ')', checks.mtu_probe ? checks.mtu_probe.status : null, mtuProbeRtt);

            var mtu6ProbeSource = (checks.mtu6_probe && checks.mtu6_probe.source) ? checks.mtu6_probe.source : '-';
            var mtu6ProbeTarget = (checks.mtu6_probe && checks.mtu6_probe.target) ? checks.mtu6_probe.target : '2606:4700:4700::1111';
            var mtu6ProbePayload = (checks.mtu6_probe && checks.mtu6_probe.payload) ? checks.mtu6_probe.payload : '-';
            var mtu6ProbeIpTotal = '-';
            if (mtu6ProbePayload !== '-' && !isNaN(parseInt(mtu6ProbePayload, 10))) {
                mtu6ProbeIpTotal = String(parseInt(mtu6ProbePayload, 10) + 48);
            }
            var mtu6ProbeRtt = (checks.mtu6_probe && checks.mtu6_probe.rtt_ms && checks.mtu6_probe.rtt_ms !== '-') ? (' (' + checks.mtu6_probe.rtt_ms + ' ms)') : '';
            html += line('IPv6 MTU probe (DF Ping)', 'source: ' + mtu6ProbeSource + ' -> target: ' + mtu6ProbeTarget + ', payload: ' + mtu6ProbePayload + ' bytes (IPv6 total: ' + mtu6ProbeIpTotal + ')', checks.mtu6_probe ? checks.mtu6_probe.status : null, mtu6ProbeRtt);

            var mtuFragSource = (checks.mtu_fragmentation && checks.mtu_fragmentation.source) ? checks.mtu_fragmentation.source : '-';
            var mtuFragTarget = (checks.mtu_fragmentation && checks.mtu_fragmentation.target) ? checks.mtu_fragmentation.target : '1.1.1.1';
            var mtuFragPayload = (checks.mtu_fragmentation && checks.mtu_fragmentation.payload) ? checks.mtu_fragmentation.payload : '-';
            var mtuFragIpTotal = '-';
            if (mtuFragPayload !== '-' && !isNaN(parseInt(mtuFragPayload, 10))) {
                mtuFragIpTotal = String(parseInt(mtuFragPayload, 10) + 28);
            }
            var mtuFragRtt = (checks.mtu_fragmentation && checks.mtu_fragmentation.rtt_ms && checks.mtu_fragmentation.rtt_ms !== '-') ? (' (' + checks.mtu_fragmentation.rtt_ms + ' ms)') : '';
            html += line('IPv4 large packet fragmentation test', 'source: ' + mtuFragSource + ' -> target: ' + mtuFragTarget + ', payload: ' + mtuFragPayload + ' bytes (IP total: ' + mtuFragIpTotal + ', DF: off)', checks.mtu_fragmentation ? checks.mtu_fragmentation.status : null, mtuFragRtt);

            var mtu6FragSource = (checks.mtu6_fragmentation && checks.mtu6_fragmentation.source) ? checks.mtu6_fragmentation.source : '-';
            var mtu6FragTarget = (checks.mtu6_fragmentation && checks.mtu6_fragmentation.target) ? checks.mtu6_fragmentation.target : '2606:4700:4700::1111';
            var mtu6FragPayload = (checks.mtu6_fragmentation && checks.mtu6_fragmentation.payload) ? checks.mtu6_fragmentation.payload : '-';
            var mtu6FragIpTotal = '-';
            if (mtu6FragPayload !== '-' && !isNaN(parseInt(mtu6FragPayload, 10))) {
                mtu6FragIpTotal = String(parseInt(mtu6FragPayload, 10) + 48);
            }
            var mtu6FragRtt = (checks.mtu6_fragmentation && checks.mtu6_fragmentation.rtt_ms && checks.mtu6_fragmentation.rtt_ms !== '-') ? (' (' + checks.mtu6_fragmentation.rtt_ms + ' ms)') : '';
            html += line('IPv6 large packet fragmentation test', 'source: ' + mtu6FragSource + ' -> target: ' + mtu6FragTarget + ', payload: ' + mtu6FragPayload + ' bytes (IPv6 total: ' + mtu6FragIpTotal + ')', checks.mtu6_fragmentation ? checks.mtu6_fragmentation.status : null, mtu6FragRtt);

            var puTarget = (checks.prefix_update && checks.prefix_update.target) ? checks.prefix_update.target : '-';
            var dnsATarget = (checks.resolve_a && checks.resolve_a.target) ? checks.resolve_a.target : 'one.one.one.one';
            var dnsAAnswer = (checks.resolve_a && checks.resolve_a.answer && checks.resolve_a.answer !== '-') ? (' -> ' + checks.resolve_a.answer) : '';
            html += line('DNS A name resolution', dnsATarget, checks.resolve_a ? checks.resolve_a.status : null, dnsAAnswer);

            var curlV4Source = (checks.curl_v4 && checks.curl_v4.source) ? checks.curl_v4.source : '-';
            var curlV4Target = (checks.curl_v4 && checks.curl_v4.target) ? checks.curl_v4.target : 'https://one.one.one.one/';
            var curlV4RemoteIp = (checks.curl_v4 && checks.curl_v4.remote_ip && checks.curl_v4.remote_ip !== '-') ? (', remote: ' + checks.curl_v4.remote_ip) : '';
            var curlV4Code = (checks.curl_v4 && checks.curl_v4.http_code && checks.curl_v4.http_code !== '-') ? (' (HTTP ' + checks.curl_v4.http_code + curlV4RemoteIp + ')') : '';
            html += line('IPv4 curl one.one.one.one', 'source: ' + curlV4Source + ' -> target: ' + curlV4Target, checks.curl_v4 ? checks.curl_v4.status : null, curlV4Code);

            var dnsAAAATarget = (checks.resolve_aaaa && checks.resolve_aaaa.target) ? checks.resolve_aaaa.target : 'one.one.one.one';
            var dnsAAAAAnswer = (checks.resolve_aaaa && checks.resolve_aaaa.answer && checks.resolve_aaaa.answer !== '-') ? (' -> ' + checks.resolve_aaaa.answer) : '';
            html += line('DNS AAAA name resolution', dnsAAAATarget, checks.resolve_aaaa ? checks.resolve_aaaa.status : null, dnsAAAAAnswer);

            var curlV6Source = (checks.curl_v6 && checks.curl_v6.source) ? checks.curl_v6.source : '-';
            var curlV6Target = (checks.curl_v6 && checks.curl_v6.target) ? checks.curl_v6.target : 'https://one.one.one.one/';
            var curlV6RemoteIp = (checks.curl_v6 && checks.curl_v6.remote_ip && checks.curl_v6.remote_ip !== '-') ? (', remote: ' + checks.curl_v6.remote_ip) : '';
            var curlV6Code = (checks.curl_v6 && checks.curl_v6.http_code && checks.curl_v6.http_code !== '-') ? (' (HTTP ' + checks.curl_v6.http_code + curlV6RemoteIp + ')') : '';
            html += line('IPv6 curl one.one.one.one', 'source: ' + curlV6Source + ' -> target: ' + curlV6Target, checks.curl_v6 ? checks.curl_v6.status : null, curlV6Code);

            $('#diag_checks').html('<div class="ocn-checks">' + html + '</div>');
        }

        function runDiagnostics() {
            $('#diag_summary').html('<div class="text-muted">Checking summary...</div>');
            $('#diag_checks').html('<div class="text-muted">Checking...</div>');
            ajaxGet('/api/ocnfixedip/service/diagnostics', {}, function(data) {
                renderChecks(data);
            });
        }

        runDiagnostics();
    });
</script>

<div class="content-box" style="padding: 10px;">
    <div class="content-box-header">
        <h3>{{ lang._('OCN Fixed IP (IPoE) Endpoint Diagnostics') }}</h3>
    </div>
    <div class="content-box-main">
        <div id="diag_checks">Loading...</div>
        <div id="diag_summary" style="margin-top:10px; margin-bottom:8px;">Loading summary...</div>
    </div>
</div>
