import test from 'node:test';
import assert from 'node:assert/strict';
import {tmdbCandidateScore} from '../src/cinemaCandidateScore.js';

test('identical normalized title and year scores well but never automatically saves',()=>{
 assert.equal(tmdbCandidateScore({kind:'movie',title:'电影 甲',year:2024},{kind:'movie',title:'电影甲',year:'2024'}),95);
 assert.equal(tmdbCandidateScore({kind:'series',title:'Example Show',year:2021},{kind:'tv',title:'example_show',year:'2021'}),95);
});
test('rejects cross-type, unrelated and low-confidence candidates',()=>{
 assert.equal(tmdbCandidateScore({kind:'movie',title:'Movie.One',year:2024},{kind:'tv',title:'Movie One',year:'2024'}),0);
 assert.equal(tmdbCandidateScore({kind:'movie',title:'Movie.One',year:2024},{kind:'movie',title:'Completely different',year:'2024'}),20);
 assert.equal(tmdbCandidateScore({kind:'movie',title:'Movie.One',year:2024},{kind:'movie',title:'Movie One',year:'2023'}),75);
 assert.equal(tmdbCandidateScore({kind:'movie',title:'Movie.One',year:0},{kind:'movie',title:'Movie',year:'2024'}),48);
});
