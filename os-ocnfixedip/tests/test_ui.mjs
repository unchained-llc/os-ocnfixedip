import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';

const root = resolve(import.meta.dirname, '../src/opnsense');
const escape = value => String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// Execute the actual page code with a minimal DOM facade. Network calls are stubbed.
function page(name, language) {
    let ready;
    const elements = new Map();
    const timers = [];
    const requests = [];
    const document = { documentElement: {lang: language}, querySelectorAll: () => [], createTextNode: v => v };
    function $(key) {
        if (key === document) return { ready: callback => { ready = callback; } };
        if (!elements.has(key)) elements.set(key, { content: '', value: '', classes: new Set() });
        const node = elements.get(key);
        const chain = {
            text(value) { if (value === undefined) return node.value; node.value = String(value); node.content = escape(value); return chain; },
            html(value) { if (value === undefined) return node.content; node.content = value; return chain; },
            empty() { node.content = ''; return chain; },
            append(value) { node.content += typeof value === 'string' ? escape(value) : value.html(); return chain; },
            attr() { return chain; }, prop() { return chain; }, parent() { return chain; }, hide() { return chain; }, show() { return chain; },
            addClass() { return chain; }, removeClass() { return chain; }, selectpicker() { return chain; }, on(type, callback) { node[type] = callback; return chain; },
        };
        return chain;
    }
    const context = vm.createContext({document, $, setTimeout: fn => {timers.push(fn); return timers.length;}, clearTimeout: () => {},
        mapDataToFormUI: () => ({done: fn => fn()}), formatTokenizersUI: () => {}, updateServiceControlUI: () => {},
        saveFormToEndpoint: (url, form, ok) => ok(),
        ajaxGet: (url, data, cb) => requests.push({url,cb}), ajaxCall: (url, data, cb) => requests.push({url,cb}),
    });
    const volt = readFileSync(root + '/mvc/app/views/OPNsense/OCNFixedIP/' + name + '.volt', 'utf8');
    assert.ok(!volt.includes('i18n.js'), 'Plugin pages must not depend on a localization module');
    const script = volt.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1].replace(/^\s*import .*;$/m, '');
    vm.runInContext(script, context);
    ready();
    return {elements, requests, timers, context};
}

for (const language of ['en_US', 'ja_JP']) {
    const state = page('general', language);
    assert.equal(state.requests.length, 1);
    state.requests.shift().cb({tunnel:{status:'up',health:'degraded',connectivity:'connected',health_failures:'mtu',reason:'<img onerror=x>'}}, 'success');
    const text = state.elements.get('#tunnel_connectivity').content;
    assert.equal(text, 'Connected (degraded)');
    assert.equal(state.elements.get('#tunnel_reason').content, '&lt;img onerror=x&gt;');
    assert.equal(state.timers.length, 1);
    state.elements.get('#saveAct').click();
    assert.equal(state.requests[0].url, '/api/ocnfixedip/service/reconfigure');
    state.requests.shift().cb({result:'failed',phase:'tunnel'}, 'success');
    assert.ok(state.elements.get('#apply_result').content.includes('Apply failed'));
    assert.equal(state.requests.length, 1);
}
const diagnostic = page('diagnostics', 'ja_JP');
assert.equal(diagnostic.requests[0].url, '/api/ocnfixedip/service/diagnostics');
diagnostic.requests.shift().cb({checks:{prefix_update:{target:'<img src=x onerror=alert(1)>',result:'"<script>x</script>',status:'ng'}}});
const output = diagnostic.elements.get('#diag_checks').content;
assert.ok(output.includes('&lt;img src=x onerror=alert(1)&gt;'));
assert.ok(!output.includes('<script>'));
assert.ok(output.includes('Prefix update API check'));
const failedDiagnostic = page('diagnostics', 'ja_JP');
failedDiagnostic.requests.shift().cb({});
assert.ok(failedDiagnostic.elements.get('#diag_checks').content.includes('No diagnostics data returned.'));
console.log('Passed: English settings rendering regardless of UI locale, Apply errors, polling, diagnostics HTML escaping and request failures');

// Exercise the dashboard tick, including the error path before data exists.
for (const language of ['en_US', 'ja_JP']) {
    const context = vm.createContext({document:{documentElement:{lang:language}}, $: () => {
        let value = '';
        const node = {text(v){value=v;return node;}, html(){return escape(value);}};
        return node;
    }, BaseTableWidget: class {updateTable(...args){this.rendered=args;}}});
    assert.ok(!readFileSync(root + '/www/js/widgets/OCNFixedIP.js', 'utf8').includes('i18n.js'));
    const widget = readFileSync(root + '/www/js/widgets/OCNFixedIP.js', 'utf8')
        .replace(/^import .*;\n/, '').replace('export default class OCNFixedIP', 'class OCNFixedIP');
    vm.runInContext(widget + '\nglobalThis.widget = new OCNFixedIP();', context);
    const instance = context.widget;
    instance.ajaxCall = async () => ({tunnel:{status:'up',health:'degraded',connectivity:'connected',local_v6:'<img>',health_failures:'<script>'}});
    instance.dataChanged = () => true;
    await instance.onWidgetTick();
    assert.ok(instance.rendered[1][0][1].includes('&lt;img&gt;'));
    assert.ok(instance.rendered[1][0][0].includes('Connected (degraded)'));
    instance.ajaxCall = async () => {throw new Error('offline');};
    instance.displayError = message => {instance.error = message; instance._renderFailed = true;};
    await instance.onWidgetTick();
    assert.ok(instance.error.includes('request failed'));
    instance.ajaxCall = async () => ({tunnel:{status:'up',health:'healthy'}});
    instance.dataChanged = () => false;
    instance.rendered = null;
    await instance.onWidgetTick();
    assert.ok(instance.rendered, 'Widget must recover from an error even when status is unchanged');
}
console.log('Passed: English dashboard state regardless of UI locale, escaping and network failure handling');
