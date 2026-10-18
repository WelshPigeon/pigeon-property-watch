/**
 * Runs the exact SQL from server/queries.lua against a real MariaDB, with tables shaped like
 * nolag_properties, qbx_properties, QBCore/Qbox players and ESX users, and checks the results.
 *
 * CI starts MariaDB as a service. To run it yourself against a throwaway database:
 *     lua tests/dump-queries.lua > queries.json
 *     npm install --no-save mysql2@3.11.3
 *     DB_HOST=127.0.0.1 DB_USER=root DB_PASSWORD=secret node tests/sql.test.mjs
 *
 * It creates and drops its own databases (pw_test_nolag, pw_test_qbx); never point it at a live server.
 */

import { readFileSync } from 'node:fs';
import mysql from 'mysql2/promise';

const Q = JSON.parse(readFileSync('queries.json', 'utf8'));
const DAY = 86400;

let passed = 0;
let failed = 0;
function check(name, ok, detail) {
    if (ok) {
        passed++;
    } else {
        failed++;
        console.log(`  \x1b[31mFAIL\x1b[0m  ${name}${detail !== undefined ? `\n          ${JSON.stringify(detail)}` : ''}`);
    }
}
const near = (a, b, tolerance = 5) => Math.abs(Number(a) - Number(b)) <= tolerance;

const root = await mysql.createConnection({
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 3306),
    user: process.env.DB_USER ?? 'root',
    password: process.env.DB_PASSWORD ?? '',
    multipleStatements: true,
    // Match oxmysql: return DATETIME values as numbers is irrelevant here, we only read UNIX_TIMESTAMP().
});

console.log('Pigeon Property Watch SQL tests');

async function freshDatabase(name) {
    await root.query(`DROP DATABASE IF EXISTS \`${name}\`; CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; USE \`${name}\`;`);
    await root.query(Q.createActivity);
    await root.query(Q.createNotices);
}
const [[{ now }]] = await root.query('SELECT UNIX_TIMESTAMP() AS now');

// ---------------------------------------------------------------------------
// NoLag Properties (same columns the queries use, shaped like its own SQL)

await freshDatabase('pw_test_nolag');
await root.query(`
    CREATE TABLE properties_owners (
        id INT AUTO_INCREMENT PRIMARY KEY,
        property_id INT NULL,
        type ENUM('society', 'user') NULL,
        identifier VARCHAR(46) NULL,
        purchase_date DATE NULL DEFAULT (CURDATE())
    );
    CREATE TABLE properties (
        id INT AUTO_INCREMENT PRIMARY KEY,
        address VARCHAR(50) NULL,
        label VARCHAR(50) NULL,
        keyholders MEDIUMTEXT NULL DEFAULT '[]',
        ownerid INT NULL,
        last_entered DATETIME NULL
    );
    INSERT INTO properties_owners (id, property_id, type, identifier, purchase_date) VALUES
        (1, 1, 'user', 'CID1', CURDATE() - INTERVAL 100 DAY),
        (2, 2, 'user', 'CID2', CURDATE() - INTERVAL 10 DAY),
        (3, 3, 'society', 'police', CURDATE() - INTERVAL 300 DAY),
        (4, 5, 'user', NULL, CURDATE());
    INSERT INTO properties (id, address, label, keyholders, ownerid, last_entered) VALUES
        (1, '5 Mirror Park', 'Mirror Park House', '{"KEY1":true}', 1, NOW() - INTERVAL 40 DAY),
        (2, '9 Vinewood', 'Vinewood Flat', '[]', 2, NULL),
        (3, 'MRPD', 'Police Garage', '[]', 3, NOW() - INTERVAL 90 DAY),
        (4, 'For sale', 'Empty', '[]', NULL, NULL),
        (5, 'Broken', 'No identifier', '[]', 4, NOW() - INTERVAL 50 DAY);
`);

{
    const [rows] = await root.query(Q.nolagFetch, [0]);
    const byId = Object.fromEntries(rows.map((r) => [r.id, r]));
    check('NoLag: only player-owned properties with an identifier', rows.map((r) => r.id).sort().join(',') === '1,2', rows.map((r) => r.id));
    check('NoLag: last activity is last_entered', near(byId[1].last_activity, now - 40 * DAY), byId[1].last_activity);
    check('NoLag: never entered falls back to the purchase date', byId[2] && Math.abs(Number(byId[2].last_activity) - (now - 10 * DAY)) < DAY, byId[2]?.last_activity);
    check('NoLag: owner, type, label, address and keyholders come through', byId[1].owner === 'CID1' && byId[1].owner_type === 'user' && byId[1].label === 'Mirror Park House' && byId[1].address === '5 Mirror Park' && byId[1].keyholders === '{"KEY1":true}', byId[1]);
    check('NoLag: database time is returned', near(byId[1].db_now, now, 10));

    const [withSociety] = await root.query(Q.nolagFetch, [1]);
    check('NoLag: society-owned included when asked', withSociety.map((r) => r.id).sort().join(',') === '1,2,3', withSociety.map((r) => r.id));
}

// ---------------------------------------------------------------------------
// Qbox properties (columns from qbx_properties' property.sql)

await freshDatabase('pw_test_qbx');
await root.query(`
    CREATE TABLE properties (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        property_name VARCHAR(255) NOT NULL,
        owner VARCHAR(50) NULL,
        keyholders JSON NOT NULL
    );
    INSERT INTO properties (id, property_name, owner, keyholders) VALUES
        (1, 'Apartment 1', 'CIDA', '["FRIEND"]'),
        (2, 'House 2', 'CIDB', '[]'),
        (3, 'Unowned', NULL, '[]'),
        (10, 'House 10', 'CIDZ', '[]');
`);

{
    const [first] = await root.query(Q.qbxBaseline);
    check('Qbox: first sync starts tracking every owned property', first.affectedRows === 3, first.affectedRows);
    const [second] = await root.query(Q.qbxBaseline);
    check('Qbox: second sync adds nothing', second.affectedRows === 0, second.affectedRows);

    const [tracked] = await root.query("SELECT property_id, owner, UNIX_TIMESTAMP(last_activity) AS t FROM pigeon_property_activity WHERE `system` = 'qbx_properties' ORDER BY property_id");
    check('Qbox: tracked with owner and the current time', tracked.length === 3 && tracked.every((r) => near(r.t, now, 10)) && tracked.find((r) => r.property_id === '1').owner === 'CIDA', tracked);

    // Pretend properties 1 and 2 were last used 40 days ago.
    await root.query("UPDATE pigeon_property_activity SET last_activity = NOW() - INTERVAL 40 DAY WHERE property_id IN ('1', '2')");
    const [fetched] = await root.query(Q.qbxFetch);
    const byId = Object.fromEntries(fetched.map((r) => [r.id, r]));
    check('Qbox: fetch returns owned, tracked properties', fetched.map((r) => r.id).sort((a, b) => a - b).join(',') === '1,2,10', fetched.map((r) => r.id));
    check('Qbox: fetch returns last activity, label, owner and keyholders', near(byId[1].last_activity, now - 40 * DAY, 10) && byId[1].label === 'Apartment 1' && byId[1].owner === 'CIDA' && JSON.stringify(JSON.parse(byId[1].keyholders)) === '["FRIEND"]', byId[1]);

    // Property 10 must not be confused with property 1 (IDs are stored as text).
    check('Qbox: property 10 isn\'t matched to property 1', near(byId[10].last_activity, now, 10), byId[10]);

    // Property 2 is sold.
    await root.query("UPDATE properties SET owner = 'CIDC' WHERE id = 2");
    const [reset] = await root.query(Q.qbxOwnerReset);
    check('Qbox: owner change resets exactly one property', reset.affectedRows === 1, reset.affectedRows);
    const [[after]] = await root.query("SELECT owner, UNIX_TIMESTAMP(last_activity) AS t FROM pigeon_property_activity WHERE property_id = '2'");
    check('Qbox: new owner and fresh clock', after.owner === 'CIDC' && near(after.t, now, 10), after);
    const [[untouched]] = await root.query("SELECT UNIX_TIMESTAMP(last_activity) AS t FROM pigeon_property_activity WHERE property_id = '1'");
    check('Qbox: other properties keep their clock', near(untouched.t, now - 40 * DAY, 10), untouched);

    // Someone enters property 1.
    const [[{ owner }]] = await root.query(Q.qbxOwner, [1]);
    check('Qbox: owner lookup', owner === 'CIDA', owner);
    await root.query(Q.qbxMarkActive, ['1', owner, owner]);
    const [[active]] = await root.query("SELECT UNIX_TIMESTAMP(last_activity) AS t FROM pigeon_property_activity WHERE property_id = '1'");
    check('Qbox: entering updates the existing record', near(active.t, now, 10), active);
    await root.query(Q.qbxMarkActive, ['3', 'NEW', 'NEW']);
    const [[inserted]] = await root.query("SELECT owner FROM pigeon_property_activity WHERE property_id = '3'");
    check('Qbox: marking an untracked property inserts it', inserted.owner === 'NEW', inserted);

    const [unowned] = await root.query(Q.qbxOwner, [3]);
    check('Qbox: unowned property has no owner', unowned[0].owner === null, unowned);
}

// ---------------------------------------------------------------------------
// Notices

{
    await root.query(Q.noticeInsert, ['qbx:1:inactive:A:100', 'qbx_properties', '1', 'inactive']);
    const [again] = await root.query(Q.noticeInsert, ['qbx:1:inactive:A:100', 'qbx_properties', '1', 'inactive']);
    check('Notices: the same notice is stored once', again.affectedRows === 0, again.affectedRows);
    const [sent] = await root.query(Q.noticesSent_2, ['qbx:1:inactive:A:100', 'qbx:2:inactive:B:200']);
    check('Notices: finds which notices were already sent', sent.length === 1 && sent[0].notice_key === 'qbx:1:inactive:A:100', sent);
    const longKey = `nolag_properties:${'9'.repeat(20)}:warning:${'x'.repeat(46)}:${'1'.repeat(12)}`;
    await root.query(Q.noticeInsert, [longKey, 'nolag_properties', '9'.repeat(20), 'warning']);
    const [[stored]] = await root.query('SELECT notice_key FROM pigeon_property_notices WHERE notice_key = ?', [longKey]);
    check('Notices: the longest possible key fits', stored?.notice_key === longKey, longKey.length);
}

// ---------------------------------------------------------------------------
// Names

{
    await root.query(`
        CREATE TABLE players (citizenid VARCHAR(50) PRIMARY KEY, charinfo TEXT);
        INSERT INTO players VALUES ('CIDA', '{"firstname":"Pigeon","lastname":"McPigeon"}'), ('CIDB', '{"firstname":"Other","lastname":"Person"}');
        CREATE TABLE users (identifier VARCHAR(60) PRIMARY KEY, firstname VARCHAR(16), lastname VARCHAR(16));
        INSERT INTO users VALUES ('char1:abc', 'Esx', 'Person');
    `);
    const [qbx] = await root.query(Q.namesQbx_2, ['CIDA', 'MISSING']);
    check('Names: players table, by citizen ID', qbx.length === 1 && qbx[0].id === 'CIDA' && JSON.parse(qbx[0].charinfo).firstname === 'Pigeon', qbx);
    const [esx] = await root.query(Q.namesEsx_1, ['char1:abc']);
    check('Names: users table, by identifier', esx.length === 1 && esx[0].firstname === 'Esx' && esx[0].lastname === 'Person', esx);
}

// ---------------------------------------------------------------------------
// Tables can be created again on every start

{
    let ok = true;
    try {
        await root.query(Q.createActivity);
        await root.query(Q.createNotices);
    } catch {
        ok = false;
    }
    check('Creating the tables again on restart is harmless', ok);
}

await root.query('DROP DATABASE IF EXISTS pw_test_nolag; DROP DATABASE IF EXISTS pw_test_qbx;');
await root.end();

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
