-- gen1recomp for PSP: LÖVE configuration read by the lovepsp runtime.
function love.conf(t)
  -- same save identity as the desktop build, so a desktop save folder
  -- (pokemon-love2d/) can be copied to the PSP as-is
  t.identity = "pokemon-love2d"
  t.window.title = "gen1recomp for PSP"
  t.window.width = 480
  t.window.height = 272
  t.modules.physics = false
end
