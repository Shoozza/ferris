--[[
	sprite ecs
]]

local path = (...):gsub("systems.sprite_system", "")
local base = require(path .. "base_system")

--sprite type
local sprite = class()

function sprite:new(texture)
	return self:init({
		--xy
		pos = vec2:zero(),
		size = vec2:zero(),
		offset = vec2:zero(),
		--uv
		framesize = vec2:xy(1,1),
		frame = vec2:zero(),
		--z ordering
		z = 0,
		--rotation
		rot = 0,
		--enable/disable
		visible = true,
		--track if we were on screen last frame
		on_screen = true,
		--mirror orientation (could just be scale?..)
		x_flipped = false,
		y_flipped = false,
		--tex
		texture = texture,
		--worldspace
		_screenpos = vec2:zero(),
		_screen_rotation = 0,
	})
end

local _sprite_draw_temp_pos = vec2:zero()
function sprite:draw(quad, use_screenpos)
	local pos
	local rot

	if use_screenpos then
		--position in screenspace
		pos = self._screenpos
		rot = self._screen_rotation
	else
		pos = _sprite_draw_temp_pos:vset(self.pos):vaddi(self.offset)
		rot = self.rot
	end

	local size = self.size
	local frame = self.frame
	local framesize = self.framesize
	quad:setViewport(
		frame.x * framesize.x, frame.y * framesize.y,
		framesize.x, framesize.y
	)
	love.graphics.draw(
		self.texture, quad,
		pos.x, pos.y,
		rot,
		--TODO: just have scale here rather than flipped bools
		(self.x_flipped and -1 or 1) * (size.x / framesize.x),
		(self.y_flipped and -1 or 1) * (size.y / framesize.y),
		--centred
		0.5 * framesize.x, 0.5 * framesize.y,
		--no shear
		0, 0
	)
end

local sprite_system = class()

function sprite_system:new(args)
	args = args or {}
	local s = self:init({
		--function for getting the screen pos
		transform_fn = args.transform_fn,
		--the camera to use for culling, or true to use kernel cam,
		--or false/nil to use nothing
		camera = args.camera,
		--whether to cull or draw on screen or untransformed
		cull_screen = type(args.cull_screen) == "boolean"
			and args.cull_screen
			or true,
		draw_screen = type(args.draw_screen) == "boolean"
			and args.draw_screen
			or true,
		shader = args.shader,
		--texture ordering
		texture_order_mapping = unique_mapping:new(),
		--list of sprites
		sprites = {},
		--filtered list
		sprites_to_render = {},
		--debug info
		debug = {
			sprites = 0,
			rendered = 0,
		},
	})

	return s
end

function sprite_system:add(texture)
	local s = sprite:new(texture)
	table.insert(self.sprites, s)
	return s
end

function sprite_system:remove(s)
	table.remove_value(self.sprites, s)
end

function sprite_system:flush(camera)
	if type(self.transform_fn) == "function" then
		--apply transformation function
		table.foreach(self.sprites, function(s)
			local tx, ty, rot = self.transform_fn(s)
			if tx then s._screenpos.x = tx end
			if ty then s._screenpos.y = ty end
			if rot then s._screen_rotation = rot + s.rot end
		end
		)
	else
		--copy
		table.foreach(self.sprites, function(s)
			s._screenpos:vset(s.pos):vaddi(s.offset)
			s._screen_rotation = s.rot
		end)
	end

	--collect on screen to render
	local filter_function = nil
	if camera == nil then
		filter_function = function(s)
			return s.visible
		end
	else
		if self.cull_screen then
			filter_function = function(s)
				return s.visible and camera:aabb_on_screen(s._screenpos, s.size)
			end
		else
			filter_function = function(s)
				return s.visible and camera:aabb_on_screen(s.pos, s.size)
			end
		end
	end
	local function write_filter_result(s)
		local result = filter_function(s)
		s.on_screen = result
		return result
	end
	self.sprites_to_render = table.filter(self.sprites, write_filter_result)

	--sort to render
	local _torder = self.texture_order_mapping
	local function _texture_order(tex)
		return _torder:map(tex)
	end
	table.stable_sort(self.sprites_to_render, function(a, b)
		if a.z == b.z then
			--secondary sort on texture within z level for batching
			return _texture_order(a.texture) < _texture_order(b.texture)
		end
		return a.z < b.z
	end)

	--update debug info
	self.debug.sprites = #self.sprites
	self.debug.rendered = #self.sprites_to_render

end

--draw all the sprites
function sprite_system:draw()
	local q = love.graphics.newQuad(0,0,1,1,1,1)

	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(self.shader)
	table.foreach(self.sprites_to_render, function(s)
		s:draw(q, self.draw_screen)
	end)
end

--register tasks for kernel
function sprite_system:register(kernel, order)
	kernel:add_task("update", function(k, dt)
		local use_cam
		if type(self.camera) == "boolean" and self.camera then
			--grab the kernel cam
			use_cam = kernel.camera
		else
			--(handles the nil, table, and false cases)
			use_cam = self.camera
		end

		if use_cam then
			--cull to kernel cam
			self:flush(use_cam)
		else
			--no visibility culling
			self:flush()
		end
	end, order + 1000)
	kernel:add_task("draw", function(k)
		self:draw()
	end, order)
end

--console debug
function sprite_system:add_console_watch(name, console)
	console:add_watch(name, function()
		return table.concat({
			self.debug.sprites, "s, ",
			self.debug.rendered, "r"
		}, "")
	end)
end

return sprite_system
