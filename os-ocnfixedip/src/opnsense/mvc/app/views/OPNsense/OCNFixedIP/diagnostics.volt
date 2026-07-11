{#
 # Copyright (C) 2024 OCN Fixed IP (IPoE) Plugin Contributors
 # All rights reserved.
 #}

<script>
    $( document ).ready(function() {
        function runDiagnostics() {
            $('#diag_output').text('Running diagnostics...');
            ajaxGet('/api/ocnfixedip/service/diagnostics', {}, function(data) {
                if (!data) {
                    $('#diag_output').text('Error: No response from backend');
                    return;
                }

                var output = '';
                if (data.interface) {
                    output += '=== Tunnel Interface ===\n' + data.interface + '\n\n';
                }
                if (data.routes) {
                    output += '=== IPv4 Routes ===\n' + data.routes + '\n\n';
                }
                if (data.ping) {
                    output += '=== Connectivity Test ===\n' + data.ping + '\n\n';
                }


                $('#diag_output').text(output || 'No data returned');
            });
        }

        $('#refreshDiag').click(function() {
            runDiagnostics();
        });

        runDiagnostics();
    });
</script>

<div class="content-box" style="padding: 10px;">
    <div class="content-box-header">
        <h3>{{ lang._('OCN Fixed IP (IPoE) IPIP Diagnostics') }}</h3>
    </div>
    <div class="content-box-main">
        <button class="btn btn-primary" id="refreshDiag" type="button">
            <i class="fa fa-refresh"></i> {{ lang._('Refresh') }}
        </button>
        <hr />
        <pre id="diag_output" style="max-height: 500px; overflow-y: auto;">Loading...</pre>
    </div>
</div>
