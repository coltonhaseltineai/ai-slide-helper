#!/usr/bin/env node
// Signs the app zip for Sparkle and writes appcast.xml, the feed the app checks for updates.
// Usage: SPARKLE_PRIVATE_KEY=<base64 seed> node make-appcast.js <zip> <build> <downloadURL> <notes> <out>
const crypto = require('crypto');
const fs = require('fs');

const [zipPath, build, url, notes = '', out = 'appcast.xml'] = process.argv.slice(2);
const seed = Buffer.from(process.env.SPARKLE_PRIVATE_KEY || '', 'base64');
if (!zipPath || !build || !url || seed.length !== 32) {
  console.error('Need <zip> <build> <downloadURL> and a 32-byte base64 SPARKLE_PRIVATE_KEY.');
  process.exit(1);
}

// Wrap the raw Ed25519 seed in PKCS#8 so Node can load it.
const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
const data = fs.readFileSync(zipPath);
const signature = crypto.sign(null, data, key).toString('base64');

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const xml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Live Outline</title>
    <item>
      <title>Version 1.${esc(build)}</title>
      <pubDate>${new Date().toUTCString()}</pubDate>
      <sparkle:version>${esc(build)}</sparkle:version>
      <sparkle:shortVersionString>1.${esc(build)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>${esc(notes)}</p>]]></description>
      <enclosure url="${esc(url)}" length="${data.length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
    </item>
  </channel>
</rss>
`;
fs.writeFileSync(out, xml);
console.log(`Wrote ${out} for build ${build} (${data.length} bytes)`);
