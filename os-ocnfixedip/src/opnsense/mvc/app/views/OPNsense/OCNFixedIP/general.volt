{#
 # Copyright (C) 2024 OCN Fixed IP (IPoE) Plugin Contributors
 # All rights reserved.
 #}

<script>
    $( document ).ready(function() {
        var data_get_map = {'frm_general_settings':"/api/ocnfixedip/settings/get"};
        mapDataToFormUI(data_get_map).done(function(){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });

        function setStatus(statusText, iconClass, badgeClass) {
            $('#tunnel_status').empty().append($('<span>').addClass('label ' + badgeClass).text(statusText));
            $('#status_icon').attr('class', 'fa ' + iconClass);
        }

        function showApplying() {
            setStatus('Applying...', 'fa-spinner fa-spin text-warning', 'label-warning');
            $('#tunnel_connectivity').text('configuring...');
            $('#tunnel_local_v6').text('-');
            $('#tunnel_aftr').text('-');
            $('#tunnel_ipv4').text('-');
            $('#tunnel_mtu').text('-');
            $('#tunnel_reason').text('').parent().hide();
        }

        let applying = false;
        let statusPending = false;
        let statusTimer;
        function showApplyError(message) {
            $('#apply_result').removeClass('hidden alert-warning').addClass('alert-danger').text(message);
        }
        $('#saveAct').on('click', function() {
            if (applying) return;
            applying = true;
            clearTimeout(statusTimer);
            $(this).prop('disabled', true);
            $('#apply_result').addClass('hidden');
            showApplying();
            function completeApply() {
                applying = false;
                $('#saveAct').prop('disabled', false);
                refreshStatus();
            }
            saveFormToEndpoint('/api/ocnfixedip/settings/set', 'frm_general_settings', function() {
                ajaxCall('/api/ocnfixedip/service/reconfigure', {}, function(data, status) {
                    if (status !== 'success' || !data || data.result !== 'ok') {
                        showApplyError('Apply failed. Check the system log.');
                        if (data && data.phase) $('#apply_result').append(document.createTextNode(' ' + 'Failed phase' + ': ' + data.phase));
                    } else if (data.warning) {
                        $('#apply_result').removeClass('hidden alert-danger').addClass('alert-warning').text('Prefix update failed; review Diagnostics.');
                    }
                    completeApply();
                });
            }, false, function() {
                showApplyError('Apply failed. Check the system log.');
                completeApply();
            });
        });

        function refreshStatus() {
            clearTimeout(statusTimer);
            if (statusPending || applying) return;
            statusPending = true;
            ajaxGet('/api/ocnfixedip/service/status', {}, function(data, status) {
                statusPending = false;
                statusTimer = setTimeout(refreshStatus, 5000);
                if (applying) return;
                if (status !== 'success' || !data || !data.tunnel) {
                    setStatus('Status request failed.', 'fa-exclamation-circle text-warning', 'label-warning');
                    return;
                }

                var t = data.tunnel;
                if (t.status === 'up' && t.health === 'healthy') {
                    setStatus('HEALTHY', 'fa-check-circle text-success', 'label-success');
                } else if (t.status === 'up' && t.connectivity === 'connected') {
                    setStatus('Connected (Degraded)', 'fa-exclamation-circle text-warning', 'label-warning');
                } else if (t.status === 'up' && t.connectivity === 'no internet') {
                    setStatus('Tunnel Up (No Internet)', 'fa-exclamation-circle text-warning', 'label-warning');
                } else if (t.status === 'up') {
                    setStatus('Tunnel Up', 'fa-circle text-success', 'label-success');
                } else if (t.status === 'disabled') {
                    setStatus('Disabled', 'fa-minus-circle text-muted', 'label-default');
                } else {
                    setStatus('Not Running', 'fa-circle text-danger', 'label-danger');
                }

                const connectivity = t.health === 'healthy' ? 'HEALTHY' :
                    (t.connectivity === 'connected' ? 'Connected (degraded)' :
                    (t.connectivity === 'no internet' ? 'No Internet' : t.connectivity || '-'));
                $('#tunnel_connectivity').text(connectivity);
                $('#tunnel_failures').text(t.health_failures ? 'Health failures' + ': ' + t.health_failures + '. ' + 'Probe failures are not proof of a total outage.' : '');

                $('#tunnel_local_v6').text(t.local_v6 || '-');
                $('#tunnel_aftr').text(t.aftr || '-');
                $('#tunnel_ipv4').text(t.ipv4 || '-');
                $('#tunnel_mtu').text(t.mtu || '-');

                if (t.reason) {
                    $('#tunnel_reason').text(t.reason);
                    $('#tunnel_reason').parent().show();
                } else {
                    $('#tunnel_reason').parent().hide();
                }
            });
        }

        refreshStatus();
        updateServiceControlUI('ocnfixedip');
    });
</script>

<div class="content-box" style="padding: 10px;">
    <div class="content-box-header">
        <h3>{{ lang._('OCN Fixed IP (IPoE) IPIP Status') }}</h3>
    </div>
    <div class="content-box-main">
        <table class="table table-condensed">
            <tbody>
                <tr>
                    <td style="width: 150px;"><strong>{{ lang._('Status') }}</strong></td>
                    <td><i id="status_icon" class="fa fa-circle text-muted"></i> <span id="tunnel_status"><span class="label label-default">Loading...</span></span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Connectivity') }}</strong></td>
                    <td><span id="tunnel_connectivity">-</span><div id="tunnel_failures" class="text-warning"></div></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Local IPv6') }}</strong></td>
                    <td><span id="tunnel_local_v6">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('BR IPv6') }}</strong></td>
                    <td><span id="tunnel_aftr">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Tunnel IPv4') }}</strong></td>
                    <td><span id="tunnel_ipv4">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('MTU') }}</strong></td>
                    <td><span id="tunnel_mtu">-</span></td>
                </tr>
                <tr style="display:none;">
                    <td><strong>{{ lang._('Info') }}</strong></td>
                    <td><span id="tunnel_reason" class="text-warning"></span></td>
                </tr>
            </tbody>
        </table>
    </div>
</div>

<div class="content-box" style="padding: 10px;">
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_general_settings'])}}
    <div class="col-md-12">
        <hr />
        <div id="apply_result" class="alert hidden" role="alert"></div>
        <button class="btn btn-primary" id="saveAct"
                data-endpoint='/api/ocnfixedip/service/reconfigure'
                data-label="{{ lang._('Apply') }}"
                data-error-title="{{ lang._('Error reconfiguring tunnel') }}"
                type="button">{{ lang._('Apply') }}</button>
    </div>
</div>
