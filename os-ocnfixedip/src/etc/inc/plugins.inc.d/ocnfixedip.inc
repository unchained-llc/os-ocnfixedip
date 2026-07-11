<?php

/*
 * Copyright (C) 2024 OCN Virtual Connect Fixed IP Plugin Contributors
 * All rights reserved.
 */

function ocnfixedip_enabled()
{
    $model = new \OPNsense\OCNFixedIP\OCNFixedIP();
    return (string)$model->enabled == '1';
}

function ocnfixedip_configure()
{
    return [
        'newwanip' => ['ocnfixedip_configure_do:3'],
    ];
}

function ocnfixedip_configure_do($verbose = false, $interfaces = null, $family = null)
{
    if (!ocnfixedip_enabled()) {
        return;
    }

    /*
     * rc.newwanipv6 triggers plugins_configure("newwanip", ..., "inet6").
     * Ignore IPv4-side triggers and only react to IPv6 renewal events.
     */
    if ($family !== null && $family !== 'inet6') {
        service_log('Skipping OCN Virtual Connect Fixed IP reconfigure (non-inet6 trigger).', $verbose);
        return;
    }

    service_log('Configuring OCN Virtual Connect Fixed IP tunnel...', $verbose);
    configd_run('ocnfixedip configure');
    service_log("done.\n", $verbose);
}

function ocnfixedip_firewall(\OPNsense\Firewall\Plugin $fw)
{
    return;
}


function ocnfixedip_services()
{
    $services = [];

    if (!ocnfixedip_enabled()) {
        return $services;
    }

    $services[] = [
        'description' => 'OCN Virtual Connect Fixed IP Tunnel',
        'configd' => [
            'start' => ['ocnfixedip start'],
            'restart' => ['ocnfixedip restart'],
            'stop' => ['ocnfixedip stop'],
        ],
        'name' => 'ocnfixedip',
        'nocheck' => true,
    ];

    return $services;
}

function ocnfixedip_interfaces()
{
    $interfaces = [];

    if (!ocnfixedip_enabled()) {
        return $interfaces;
    }

    $interfaces['ocnfixedip'] = [
        'descr' => gettext('OCN Virtual Connect Fixed IP (gif0)'),
        'if' => 'gif0',
        'virtual' => true,
        'enable' => true,
        'type' => 'gif',
    ];

    return $interfaces;
}

function ocnfixedip_syslog()
{
    return [
        'ocnfixedip' => ['facility' => ['ocnfixedip']]
    ];
}
