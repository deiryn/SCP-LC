local ply = FindMetaTable( "Player" )

--[[-------------------------------------------------------------------------
General Functions
---------------------------------------------------------------------------]]
function ply:SetSCPClass( class )
	self:Set_SCPClass( class )
	self:Set_SCPPersonaC( class )
end

function ply:Cleanup()
	self.ClassData = nil
	self:ClearSpeedStack()
	self:SetVest( 0 )
	self.PlayerData:Reset()

	self:SetColor( Color( 255, 255, 255 ) )
	self:SetSubMaterial()
	self:SetMaterial( "" )

	self:SetModelScale( 1 )
	self:Freeze( false )
	self:SetNoDraw( false )
	self:SetCustomCollisionCheck( false )

	self:RemoveAllItems()
end

function ply:Despawn()
	--TODO reset effects
	
	self:Freeze( false )
	self:SetCustomCollisionCheck( false )

	self.PlayerData:Reset()
	self:InvalidatePlayerForSpectate()

	net.Start( "PlayerDespawn" )
	net.Send( self )
end

function ply:SetupPlayer( class )
	self:UnSpectate()
	self:Cleanup()
	self:Spawn()

	self:Flashlight( false )
	self:AllowFlashlight( false )
	self:SetArmor( 0 )

	self:SetSCPClass( class.name )
	self:SetSCPTeam( class.team )

	if class.persona and class.persona.class then
		self:Set_SCPPersonaC( class.persona.class )
	end

	if class.persona and class.persona.team then
		self:Set_SCPPersonaT( class.persona.team )
	end

	self:Give( "item_slc_holster" )
	self:Give( "item_slc_id" )

	if class.chip and class.chip != "" then
		local keycard = self:Give( "item_slc_keycard" )
		if IsValid( keycard ) then
			keycard:SetKeycardType( class.chip )
		end
	end

	for i, v in ipairs( class.weapons ) do
		if istable( v ) then
			v = table.Random( v )
		end

		local wep = self:Give( v )

		if IsValid( wep ) then
			local ammo = class.ammo[v]

			if ammo then
				local clip = math.min( ammo, wep:GetMaxClip1() )
				local reserve = ammo - clip

				wep:SetClip1( clip )

				if reserve > 0 then
					self:GiveAmmo( reserve, wep:GetPrimaryAmmoType() )
				end
			end
		else
			print( "Failed to create weapon: "..v )
		end
	end

	self:SetMaxHealth( class.health )
	self:SetHealth( class.health )

	self:SetMaxSanity( class.max_sanity or class.sanity )
	self:SetSanity( class.sanity )

	self:SetBaseSpeed( class.walk_speed, class.run_speed, 0.5 )
	self:SetJumpPower( 175 )

	self:SetModel( istable( class.model ) and table.Random( class.model ) or class.model )
	self:SetupHands()

	hook.Run( "SLCPlayerSetup", self )

	if class.vest then
		self:EquipVest( class.vest )
	end

	self.ClassData = class

	net.Start("PlayerSetup")
	net.Send( self )
end

function ply:EquipVest( vest )
	if self:GetVest() > 0 then return end

	local t = self:SCPTeam()
	if t == TEAM_SPEC then return end
	if t == TEAM_SCP and !self.SCPHuman then return end

	if isstring( vest ) then
		vest = VEST.getID( vest )
	end

	local data = VEST.getData( vest )
	if data then
		self:SetVest( vest )
		self.OldModel = self:GetModel()
		self:SetModel( data.model )

		self.VestSpeed = self:PushSpeed( data.mobility, data.mobility, -1 )

		PlayerMessage( "vestpickup", self )
		self:EmitSound( "Player.Vest" )

		hook.Run( "SLCArmorPickedUp", self )

		return true
	end
end

function ply:DropVest()
	local vest = self:GetVest()
	if vest == 0 then return end

	if !self.OldModel then
		print( "ERROR! Failed to retrieve player model!" )
		if !self.ClassData then
			ErrorNoHalt(  "FATAL ERROR! Essential playerdata is missing! It should NEVER happen!" )
			return
		end

		self.OldModel = istable( self.ClassData.model ) and table.Random( self.ClassData.model ) or self.ClassData.model
	end

	self:SetVest( 0 )
	VEST.create( vest, self:GetPos() )
	
	self:SetModel( self.OldModel )
	self.OldModel = nil

	if !self.VestSpeed then
		print( "ERROR! Failed to restore player speed! It can cause speed errors!" )
	else
		self:PopSpeed( self.VestSpeed )
		self.VestSpeed = nil
	end

	PlayerMessage( "vestdrop", self )
	self:EmitSound( "Player.Vest" )

	hook.Run( "SLCArmorDropped", self )
end

function ply:CreatePlayerRagdoll()

end

function ply:Blink( dur, nextblink )
	self:SetBlink( true )

	net.Start( "PlayerBlink" )
		net.WriteFloat( dur )
		net.WriteUInt( nextblink, 6 )
	net.Send( self )

	Timer( "PlayerUnBlink"..self:SteamID64(), math.max( dur, 0.4 ), 1, function()
		if IsValid( self ) then
			self:SetBlink( false )
		end
	end )
end
--[[-------------------------------------------------------------------------
Premium
---------------------------------------------------------------------------]]
_OldSetUserGroup = _OldSetUserGroup or ply.SetUserGroup
function ply:SetUserGroup( ... )
	_OldSetUserGroup( self, ... )
	self:CheckPremium()
end

cvars.AddChangeCallback( CVAR.groups:GetName(), function( cvar, old, new )
	for k, v in pairs( player.GetAll() ) do
		v:CheckPremium()
	end
end, "PremiumGroups" )

function ply:CheckPremium()
	if !self.PlayerData then return end

	local groups = {}
	for s in string.gmatch( string.gsub( CVAR.groups:GetString(), "%s", "" ), "[^,]+" ) do
		table.insert( groups, s )
	end

	local premium = false

	local group = self:GetUserGroup()
	local useulib = ULib != nil

	for i, v in ipairs( groups ) do
		if useulib and self:CheckGroup( v ) or v == group then
			premium = true
			break
		end
	end

	self:SetPremium( premium )
end

--[[-------------------------------------------------------------------------
SPEED SYSTEM
---------------------------------------------------------------------------]]
function ply:PushSpeed( walk, run, crouch )
	local swalk = self:GetWalkSpeed()
	local srun = self:GetRunSpeed()
	local scrouch = self:GetCrouchedWalkSpeed()

	if !self.SpeedStack then
		self.SpeedStack = { {
			id = 0,
			walk = swalk,
			run = srun,
			crouch = scrouch,
		} }
	end

	if walk > 0 and walk < 1 then
		self:SetWalkSpeed( swalk * walk )
	elseif walk != -1 then
		self:SetWalkSpeed( walk )
	end

	if run > 0 and run < 1 then
		self:SetRunSpeed( srun * run )
	elseif run != -1 then
		self:SetRunSpeed( run )
	end


	if crouch != -1 then
		self:SetCrouchedWalkSpeed( crouch )
	end

	local id = self.SpeedStack[#self.SpeedStack].id + 1
	table.insert( self.SpeedStack, { id = id, walk = walk, run = run, crouch = crouch } )

	return id
end

local function getFirstValue( ply, id )
	for i = #ply.SpeedStack - 1, 1, -1 do
		local var = ply.SpeedStack[i][id]

		if var != -1 then
			if id != "crouch" and var > 0 and var <= 1 then
				local tmp = table.remove( ply.SpeedStack, i )
				local nv = getFirstValue( ply, id )

				table.insert( ply.SpeedStack, i, tmp )

				return nv * var
			end

			return var
		end
	end
end

function ply:PopSpeed( id )
	if !self.SpeedStack then return end
	if id == 0 then return end

	for i, v in ipairs( self.SpeedStack ) do
		if v.id == id then
			if i == #self.SpeedStack then
				local run = getFirstValue( self, "run" ) 

				self:SetWalkSpeed( getFirstValue( self, "walk" ) )
				self:SetRunSpeed( run )
				self:SetCrouchedWalkSpeed( getFirstValue( self, "crouch" ) )
			end

			table.remove( self.SpeedStack, i )
		end
	end
end

function ply:SetBaseSpeed( walk, run, crouch )
	if !self.SpeedStack then
		self.SpeedStack = {}
	end

	self.SpeedStack[1] = {
		id = 0,
		walk = walk,
		run = run,
		crouch = crouch
	}

	self:SetWalkSpeed( walk )
	self:SetRunSpeed( run )
	self:SetCrouchedWalkSpeed( crouch )
end

function ply:ClearSpeedStack()
	if !self.SpeedStack then return end
	self.SpeedStack = { self.SpeedStack[1] }
end

--[[-------------------------------------------------------------------------
Helper functions
---------------------------------------------------------------------------]]
/*Player_AddFrags = Player_AddFrags or ply.AddFrags

function ply:AddFrags( f )
	SCPTeams.addScore( self:SCPTeam(), f )
	Player_AddFrags( self, f )
end*/

function ply:SetSCPLevel( lvl )
	self:Set_SCPLevel( lvl )
	self:SetSCPData( "level", lvl )
end

function ply:AddLevel( lvl )
	local level = self:Get_SCPLevel() + lvl

	self:SetSCPLevel( level )
end

function ply:AddXP( xp )
	if !isnumber( xp ) then return end

	local lvlxp = CVAR.levelxp:GetInt()
	local plyxp = self:SCPExp()

	local ref = { 1 }

	if self:IsPremium() then
		ref[1] = ref[1] + CVAR.premiumxp:GetFloat() - 1
	end

	hook.Run( "SLCScaleXP", self, ref )

	xp = math.floor( xp * ref[1] )
	plyxp = plyxp + xp

	if plyxp >= lvlxp then
		local levels = math.floor( plyxp / lvlxp )
		plyxp = plyxp - levels * lvlxp

		self:AddLevel( levels )
		PlayerMessage( "levelup$"..self:Nick()..","..self:SCPLevel() )
	end

	self:Set_SCPExp( plyxp )
	self:SetSCPData( "xp", plyxp )

	--print( "adding exp", self, xp, plyxp )

	return xp
end