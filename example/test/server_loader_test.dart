// Unit tests for the YAML parser in `lib/src/data/server_loader.dart`.
//
// Focuses on the parser's tolerance for the upstream gist's quirks:
// Markdown-link-wrapped hostnames / owner attributions, missing
// optional fields, and outright malformed rows.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts_example/src/data/server_loader.dart';

void main() {
  group('parseServerYaml', () {
    test('parses a plain row with all fields', () {
      const yaml = '''
servers:
  - hostname: time.cloudflare.com
    stratum: 3
    location: All
    owner: Cloudflare
    notes: Anycast
    vm: false
''';
      final entries = parseServerYaml(yaml);
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.hostname, 'time.cloudflare.com');
      expect(e.displayUrl, isNull);
      expect(e.stratum, 3);
      expect(e.location, 'All');
      expect(e.owner, 'Cloudflare');
      expect(e.ownerUrl, isNull);
      expect(e.notes, 'Anycast');
      expect(e.vm, isFalse);
      expect(e.spec.host, 'time.cloudflare.com');
      expect(e.spec.port, 4460);
    });

    test('splits markdown link in hostname and owner', () {
      const yaml = '''
servers:
  - hostname: '[nts.teambelgium.net](https://ntp.teambelgium.net)'
    stratum: 1
    location: Belgium
    owner: '[ntp.br](https://ntp.br)'
    vm: false
''';
      final e = parseServerYaml(yaml).single;
      expect(e.hostname, 'nts.teambelgium.net');
      expect(e.displayUrl, 'https://ntp.teambelgium.net');
      expect(e.owner, 'ntp.br');
      expect(e.ownerUrl, 'https://ntp.br');
    });

    test('skips rows with missing or empty hostname', () {
      const yaml = '''
servers:
  - hostname: a.example.com
    location: Test
    owner: Acme
  - hostname: ''
    location: Test
    owner: Acme
  - location: Test
    owner: Acme
''';
      final entries = parseServerYaml(yaml);
      expect(entries, hasLength(1));
      expect(entries.single.hostname, 'a.example.com');
    });

    test('defaults missing optional fields gracefully', () {
      const yaml = '''
servers:
  - hostname: minimal.example.com
''';
      final e = parseServerYaml(yaml).single;
      expect(e.location, 'Unknown');
      expect(e.owner, 'Unknown');
      expect(e.stratum, isNull);
      expect(e.notes, isNull);
      expect(e.vm, isFalse);
    });

    test('returns empty list when servers key is missing or wrong type', () {
      expect(parseServerYaml('foo: bar'), isEmpty);
      expect(parseServerYaml('servers: not-a-list'), isEmpty);
      expect(parseServerYaml(''), isEmpty);
    });

    test('sorts entries by hostname', () {
      const yaml = '''
servers:
  - hostname: z.example.com
    location: Z
    owner: Z
  - hostname: a.example.com
    location: A
    owner: A
  - hostname: m.example.com
    location: M
    owner: M
''';
      final hosts = parseServerYaml(yaml).map((e) => e.hostname).toList();
      expect(hosts, ['a.example.com', 'm.example.com', 'z.example.com']);
    });
  });
}
