import test from 'node:test';
import assert from 'node:assert/strict';
import {readOpenMeteo, weatherRefreshMs} from './worker.mjs';

const clock = Date.UTC(2026, 10, 21, 21);
const event = {
  id: 'nflverse:2026_11_IND_HOU',
  startsAt: new Date(clock + 80 * 60 * 1000).toISOString(),
  latitude: 29.68,
  longitude: -95.41,
};

test('the last 90 minutes refresh the forecast sooner than the rest of the day', () => {
  assert.equal(weatherRefreshMs(event.startsAt, clock), 10 * 60 * 1000);
  assert.equal(weatherRefreshMs(new Date(clock + 6 * 3600000).toISOString(), clock), 30 * 60 * 1000);
});

test('Open-Meteo uses the hour nearest kickoff and does not invent a missing hour', () => {
  const kick = new Date(event.startsAt);
  const hour = new Date(Date.UTC(kick.getUTCFullYear(), kick.getUTCMonth(), kick.getUTCDate(), kick.getUTCHours()));
  const body = {
    hourly: {
      time: [hour.toISOString().slice(0, 16)],
      temperature_2m: [48],
      wind_speed_10m: [18],
    },
  };
  const row = readOpenMeteo(body, event, clock);
  assert.equal(row.eventId, event.id);
  assert.equal(row.source, 'Open-Meteo forecast');
  assert.equal(row.value.temperature, 48);
  assert.equal(row.value.windSpeed, '18 mph');
  assert.match(row.value.notice, /no automatic prop adjustment/);
  assert.throws(() => readOpenMeteo({hourly: {time: [], temperature_2m: []}}, event, clock));
});
