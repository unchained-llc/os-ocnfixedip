/**
 *    Copyright (C) 2024 OCN Fixed IP (IPoE) Plugin Contributors
 *
 *    All rights reserved.
 *
 *    Redistribution and use in source and binary forms, with or without
 *    modification, are permitted provided that the following conditions are met:
 *
 *    1. Redistributions of source code must retain the above copyright notice,
 *       this list of conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *
 *    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 *    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 *    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 */

export default class OCNFixedIP extends BaseTableWidget {
    constructor() {
        super();
    }

    _esc(str) {
        return $('<span>').text(str).html();
    }

    getGridOptions() {
        return {
            sizeToContent: 350
        };
    }

    getMarkup() {
        let $container = $('<div></div>');
        let $table = this.createTable('ocnfixedipStatusTable', {
            headerPosition: 'left'
        });
        $container.append($table);
        return $container;
    }

    async onWidgetTick() {
        let response;
        try {
            response = await this.ajaxCall('/api/ocnfixedip/service/status');
        } catch (e) {
            this.displayError('Status request failed.');
            return;
        }

        if (!response || !response.tunnel) {
            this.displayError('Status request failed.');
            return;
        }

        const t = response.tunnel;

        if (t.status === 'disabled') {
            this.displayError('OCN Fixed IP (IPoE) tunnel is disabled.');
            return;
        }

        const changed = this.dataChanged('ocnfixedip-status', t);
        if (!changed && !this._renderFailed) {
            return;
        }
        this._renderFailed = false;

        let statusIcon, statusText, statusClass;
        if (t.status === 'up' && t.health === 'healthy') {
            statusIcon = 'fa-check-circle text-success';
            statusText = 'HEALTHY';
            statusClass = 'text-success';
        } else if (t.status === 'up' && t.connectivity === 'connected') {
            statusIcon = 'fa-check-circle text-success';
            statusText = 'Connected (degraded)';
            statusClass = 'text-warning';
        } else if (t.status === 'up' && t.connectivity === 'no internet') {
            statusIcon = 'fa-exclamation-circle text-warning';
            statusText = 'No Internet';
            statusClass = 'text-warning';
        } else if (t.status === 'up') {
            statusIcon = 'fa-circle text-success';
            statusText = 'Tunnel Up';
            statusClass = 'text-success';
        } else {
            statusIcon = 'fa-circle text-danger';
            statusText = t.reason || 'Tunnel Down';
            statusClass = 'text-danger';
        }

        const statusLabel = `<a href="/ui/ocnfixedip/diagnostics" class="${statusClass}" title="${this._esc('Open diagnostics')}"><b>${this._esc(statusText)}</b></a>`;

        let statusRow = `
            <div style="display: flex; align-items: center; gap: 8px;">
                <i class="fa ${statusIcon}" style="font-size: 14px;"></i>
                ${statusLabel}
            </div>`;

        let detailsRow = '';
        if (t.status === 'up') {
            let failures = '';
            if (t.health && t.health !== 'healthy' && t.health_failures) {
                failures = `<div><small class="text-warning"><b>${this._esc('Health failures')}:</b> ${this._esc(t.health_failures)}</small></div>`;
            }
            detailsRow = `
                <div style="padding: 4px 0;">
                    <div><small><b>${'Local IPv6'}:</b> ${this._esc(t.local_v6 || '-')}</small></div>
                    <div><small><b>${'BR IPv6'}:</b> ${this._esc(t.aftr || '-')}</small></div>
                    <div><small><b>${'IPv4'}:</b> ${this._esc(t.ipv4 || '-')}</small></div>
                    <div><small><b>${'MTU'}:</b> ${this._esc(t.mtu || '-')}</small></div>
                    ${failures}
                </div>`;
        } else if (t.reason) {
            detailsRow = `
                <div style="padding: 4px 0;">
                    <small class="text-muted">${this._esc(t.reason)}</small>
                </div>`;
        }

        super.updateTable('ocnfixedipStatusTable', [[statusRow, detailsRow]], 'ocnfixedip-info');
    }

    displayError(message) {
        this._renderFailed = true;
        $('#ocnfixedipStatusTable').empty().append(
            $(`<div class="error-message"><a href="/ui/ocnfixedip/general">${this._esc(message)}</a></div>`)
        );
    }
}
