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
            $('#tunnel_status').html('<span class="label ' + badgeClass + '">' + statusText + '</span>');
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

        $("#saveAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                showApplying();
                saveFormToEndpoint("/api/ocnfixedip/settings/set", 'frm_general_settings', function(){
                    dfObj.resolve();
                });
                return dfObj;
            },
            onAction: function() {
                ajaxCall("/api/ocnfixedip/service/reconfigure", {}, function() {
                    updateServiceControlUI('ocnfixedip');
                    setTimeout(refreshStatus, 2000);
                    setTimeout(refreshStatus, 5000);
                });
            }
        });

        function refreshStatus() {
            ajaxGet('/api/ocnfixedip/service/status', {}, function(data) {
                if (!data || !data.tunnel) {
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

                if (t.health === 'healthy') {
                    $('#tunnel_connectivity').html('<span class="text-success">HEALTHY</span>');
                } else if (t.connectivity === 'connected') {
                    $('#tunnel_connectivity').html('<span class="text-warning">Connected (degraded)</span>');
                } else if (t.connectivity === 'no internet') {
                    $('#tunnel_connectivity').html('<span class="text-warning">No Internet</span>');
                } else {
                    $('#tunnel_connectivity').html('<span class="text-muted">' + (t.connectivity || '-') + '</span>');
                }

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
        setInterval(refreshStatus, 5000);
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
                    <td><span id="tunnel_connectivity">-</span></td>
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
        <button class="btn btn-primary" id="saveAct"
                data-endpoint='/api/ocnfixedip/service/reconfigure'
                data-label="{{ lang._('Apply') }}"
                data-error-title="{{ lang._('Error reconfiguring tunnel') }}"
                type="button">
        </button>
    </div>
</div>
