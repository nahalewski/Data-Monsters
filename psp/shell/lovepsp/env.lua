-- Default values for os.getenv() on the PSP.  Players can override any of
-- these in PSP/GAME/gen1recomp/save/pokemon-love2d/env.txt (KEY=VALUE lines).
return {
  -- Chip music is synthesized in Lua; 22050 Hz halves the work of the
  -- desktop's 44100 Hz and the Game Boy's audio sits well below 11 kHz.
  -- Drop to 11025 if music stutters.
  POKEPORT_AUDIO_RATE = "22050",
  -- there are no worker threads on the PSP port
  POKEPORT_NO_THREAD = "1",
}
