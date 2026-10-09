#!/usr/bin/ucode

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';
import { RUN_DIR } from 'homeproxy';

const cfgname = 'homeproxy';
const uci = cursor();
uci.load(cfgname);

let input = [];
if (getenv('HOMEPROXY_SERVER_READY') === '1')
	uci.foreach(cfgname, 'server', (server) => {
		if (server.enabled !== '1' || server.firewall !== '1')
			return;

		const network = server.network || '{ tcp, udp }';
		push(input, `meta l4proto ${network} th dport ${server.port} counter accept comment "!${cfgname}: accept server ${server['.name']}"`);
	});

const input_file = RUN_DIR + '/fw4_input.nft';

if (writefile(input_file, length(input) ? join('\n', input) + '\n' : '') === null)
	exit(1);

let post = [];
const kernel_block_quic = uci.get(cfgname, 'config', 'kernel_block_quic') !== '0';
if (getenv('HOMEPROXY_CLIENT_READY') === '1' && kernel_block_quic) {
	push(post, 'chain homeproxy_quic_reject {');
	push(post, '\ttype filter hook forward priority filter - 5; policy accept;');
	push(post, '\toifname "singtun0" meta l4proto udp udp dport 443 counter reject with icmpx type port-unreachable comment "!homeproxy: reject QUIC to tun"');
	push(post, '}');
}

const post_file = RUN_DIR + '/fw4_post.nft';

if (writefile(post_file, length(post) ? join('\n', post) + '\n' : '') === null)
	exit(1);
