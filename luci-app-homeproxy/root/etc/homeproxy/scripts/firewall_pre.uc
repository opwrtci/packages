#!/usr/bin/ucode

'use strict';

import { writefile, readfile } from 'fs';
import { cursor } from 'uci';
import { RUN_DIR, HP_DIR } from 'homeproxy';

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
	const china_ip4_file = HP_DIR + '/resources/china_ip4.txt';
	const china_ip4_content = readfile(china_ip4_file);
	let cidrs4 = [];
	if (china_ip4_content) {
		const raw_lines = split(china_ip4_content, '\n');
		for (let line in raw_lines) {
			line = trim(line);
			if (line) push(cidrs4, line);
		}
	}

	const ipv6_support = uci.get(cfgname, 'config', 'ipv6_support') === '1';
	let cidrs6 = [];
	if (ipv6_support) {
		const china_ip6_file = HP_DIR + '/resources/china_ip6.txt';
		const china_ip6_content = readfile(china_ip6_file);
		if (china_ip6_content) {
			const raw_lines6 = split(china_ip6_content, '\n');
			for (let line in raw_lines6) {
				line = trim(line);
				if (line) push(cidrs6, line);
			}
		}
	}

	if (length(cidrs4)) {
		push(post, 'set hp_china_ip4 {');
		push(post, '\ttype ipv4_addr');
		push(post, '\tflags interval');
		push(post, '\tauto-merge');
		push(post, '\telements = { ' + join(', ', cidrs4) + ' }');
		push(post, '}');
	}

	if (length(cidrs6)) {
		push(post, 'set hp_china_ip6 {');
		push(post, '\ttype ipv6_addr');
		push(post, '\tflags interval');
		push(post, '\tauto-merge');
		push(post, '\telements = { ' + join(', ', cidrs6) + ' }');
		push(post, '}');
	}

	push(post, 'chain homeproxy_quic_reject {');
	push(post, '\ttype filter hook prerouting priority dstnat - 5; policy accept;');
	push(post, '\tip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return');
	if (length(cidrs4))
		push(post, '\tip daddr != @hp_china_ip4 udp dport 443 counter reject with icmpx type port-unreachable comment "!homeproxy: fast reject foreign QUIC"');
	else
		push(post, '\tudp dport 443 counter reject with icmpx type port-unreachable comment "!homeproxy: fast reject foreign QUIC"');

	if (length(cidrs6)) {
		push(post, '\tip6 daddr { ::1, fe80::/10, fc00::/7 } return');
		push(post, '\tip6 daddr != @hp_china_ip6 udp dport 443 counter reject with icmpx type port-unreachable comment "!homeproxy: fast reject foreign QUIC v6"');
	}
	push(post, '}');
}

const post_file = RUN_DIR + '/fw4_post.nft';

if (writefile(post_file, length(post) ? join('\n', post) + '\n' : '') === null)
	exit(1);
