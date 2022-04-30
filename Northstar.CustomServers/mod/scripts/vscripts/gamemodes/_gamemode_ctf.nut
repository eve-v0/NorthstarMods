untyped
// this needs a refactor lol

global function CaptureTheFlag_Init
global function RateSpawnpoints_CTF

const array<string> SWAP_FLAG_MAPS = [
	"mp_forwardbase_kodai",
	"mp_lf_meadow"
]

struct {
	entity imcFlagSpawn
	entity imcFlag
	entity imcFlagReturnTrigger
	
	entity militiaFlagSpawn
	entity militiaFlag
	entity militiaFlagReturnTrigger
	
	array<entity> imcCaptureAssistList
	array<entity> militiaCaptureAssistList
} file

void function CaptureTheFlag_Init()
{
	PrecacheModel( CTF_FLAG_MODEL )
	PrecacheModel( CTF_FLAG_BASE_MODEL )
	
	CaptureTheFlagShared_Init()
	SetSwitchSidesBased( true )
	SetSuddenDeathBased( true )
	SetShouldUseRoundWinningKillReplay( true )
	SetRoundWinningKillReplayKillClasses( false, false ) // make these fully manual
	
	AddCallback_OnClientConnected( CTFInitPlayer )

	AddCallback_GameStateEnter( eGameState.Prematch, CreateFlags )
	AddCallback_GameStateEnter( eGameState.Epilogue, RemoveFlags )
	AddCallback_OnTouchHealthKit( "item_flag", OnFlagCollected )
	AddCallback_OnPlayerKilled( OnPlayerKilled )
	AddCallback_OnPilotBecomesTitan( DropFlagForBecomingTitan )
	
	SetSpawnZoneRatingFunc( DecideSpawnZone_CTF )
	
	RegisterSignal( "FlagReturnEnded" )
	RegisterSignal( "ResetDropTimeout" )
	
	// setup stuff for the functions in sh_gamemode_ctf
	// don't really like using level for stuff but just how it be
	level.teamFlags <- {}
	
	// setup score event earnmeter values
	ScoreEvent_SetEarnMeterValues( "KillPilot", 0.05, 0.20 )
	ScoreEvent_SetEarnMeterValues( "Headshot", 0.0, 0.02 )
	ScoreEvent_SetEarnMeterValues( "FirstStrike", 0.0, 0.05 )
	ScoreEvent_SetEarnMeterValues( "KillTitan", 0.0, 0.25 )
	ScoreEvent_SetEarnMeterValues( "PilotBatteryStolen", 0.0, 0.35 )
	
	ScoreEvent_SetEarnMeterValues( "FlagCarrierKill", 0.0, 0.20 )
	ScoreEvent_SetEarnMeterValues( "FlagTaken", 0.0, 0.10 )
	ScoreEvent_SetEarnMeterValues( "FlagCapture", 0.0, 0.30 )
	ScoreEvent_SetEarnMeterValues( "FlagCaptureAssist", 0.0, 0.20 )
	ScoreEvent_SetEarnMeterValues( "FlagReturn", 0.0, 0.20 )
}

const bool CTF_SPAWN_DEBUG = false

void function RateSpawnpoints_CTF( int checkClass, array<entity> spawnpoints, int team, entity player ) 
{
	// get the player's frontline and try to spawn them there, then give less good ratings as we get away from the frontline in the direction of the player's base
	Frontline frontline = GetFrontline( player.GetTeam() )

	entity ourFlag = GetFlagForTeam( player.GetTeam() )
	entity theirFlag = GetFlagForTeam( GetOtherTeam( player.GetTeam() ) )
	float flagDist = Distance2D( ourFlag.GetOrigin(), theirFlag.GetOrigin() )
	
	// weight the frontline position to be closer to friendly base
	// this is mainly done to avoid issues with frontline position being way too aggressive when people push enemy bases and that, making it pretty unfair for defending team
	vector weightedFrontline = frontline.origin
	{
		const float FRONTLINE_WEIGHT_THRESHOLD = 0.325
	
		float frontlineAngle = atan2( frontline.origin.y - ourFlag.GetOrigin().y, frontline.origin.x - ourFlag.GetOrigin().x ) * ( 180 / PI )
		float frontlineDistFrac = Distance2D( ourFlag.GetOrigin(), frontline.origin ) / flagDist
		if ( frontlineDistFrac > FRONTLINE_WEIGHT_THRESHOLD )
		{
			float fracAboveThreshold = frontlineDistFrac - FRONTLINE_WEIGHT_THRESHOLD
			fracAboveThreshold *= fracAboveThreshold * 0.45
			frontlineDistFrac = FRONTLINE_WEIGHT_THRESHOLD + fracAboveThreshold
		}
		
		weightedFrontline = ourFlag.GetOrigin() + AnglesToForward( < 0, frontlineAngle, 0 > ) * ( frontlineDistFrac * flagDist )
		
		#if CTF_SPAWN_DEBUG
			DebugDrawSphere( frontline.origin, 100, 0, 0, 255, false, 30.0, 16 )
			DebugDrawSphere( weightedFrontline, 100, 0, 255, 0, false, 30.0, 16 )
		#endif
	}
	
	float frontlineDist = Distance2D( ourFlag.GetOrigin(), weightedFrontline )
	float frontlineAngle = atan2( weightedFrontline.y - ourFlag.GetOrigin().y, weightedFrontline.x - ourFlag.GetOrigin().x ) * ( 180 / PI )
	
	// dividing dist between flags by 3ish gives a good radius for the initial circle
	// should this be based on the distance to the frontline? unsure, it probably should be based more on map size than spawn pos anyway
	float initialRatingRad = flagDist / 3.25 / 2	
		
	foreach ( entity spawnpoint in spawnpoints )
	{
		float rating
				
		// assume 150 is the max possible rating, with a range of 50-150 if within the initial rating radius, and 0-50 outside of it
		float dist = Distance2D( spawnpoint.GetOrigin(), weightedFrontline )
		if ( dist <= initialRatingRad )
		{
			rating = 50 + ( dist / initialRatingRad ) * 100
			#if CTF_SPAWN_DEBUG
				DebugDrawSphere( spawnpoint.GetOrigin(), 50, 255, 0, 0, false, 30.0, 16 )
			#endif
		}
		else
		{
			// calc angle between our spawnpoint and frontline	
			float angle = ( atan2( weightedFrontline.y - spawnpoint.GetOrigin().y, weightedFrontline.x - spawnpoint.GetOrigin().x ) * ( 180 / PI ) ) - frontlineAngle			

			// if it's <=1/3 of the distance between frontline and spawn, ensure it's within 65deg
			// otherwise, just make sure its on the same side of the map
			float frontlineSpawnDist = Distance2D( spawnpoint.GetOrigin(), weightedFrontline )
			
			if ( ( angle <= 45 && angle >= -45 ) || ( angle <= 110 && angle >= -110 && frontlineSpawnDist <= frontlineDist / 3 ) && frontlineSpawnDist < frontlineDist )
			{
				// max out at flagDist, rate better as we get closer
				rating = ( ( 1 - ( Distance2D( spawnpoint.GetOrigin(), weightedFrontline ) / frontlineDist ) ) * 50 )
				#if CTF_SPAWN_DEBUG
					DebugDrawSphere( spawnpoint.GetOrigin(), 50, 255, 200, 255 - int( ( rating / 50 ) * 255 ), false, 30.0, 16 )
				#endif
			}
		}
		
		spawnpoint.CalculateRating( checkClass, player.GetTeam(), rating, rating > 0 ? rating * 0.25 : rating )
	}
}

void function CTFInitPlayer( entity player )
{
	if ( !IsValid( file.imcFlagSpawn ) )
		return
	
	vector imcSpawn = file.imcFlagSpawn.GetOrigin()
	Remote_CallFunction_NonReplay( player, "ServerCallback_SetFlagHomeOrigin", TEAM_IMC, imcSpawn.x, imcSpawn.y, imcSpawn.z )
	
	vector militiaSpawn = file.militiaFlagSpawn.GetOrigin()
	Remote_CallFunction_NonReplay( player, "ServerCallback_SetFlagHomeOrigin", TEAM_MILITIA, militiaSpawn.x, militiaSpawn.y, militiaSpawn.z )
}

void function OnPlayerKilled( entity victim, entity attacker, var damageInfo )
{
	if ( !IsValid( GetFlagForTeam( GetOtherTeam( victim.GetTeam() ) ) ) ) // getting a crash idk
		return
	if ( GetFlagForTeam( GetOtherTeam( victim.GetTeam() ) ).GetParent() == victim )
	{
		if ( victim != attacker && attacker.IsPlayer() )
			AddPlayerScore( attacker, "FlagCarrierKill", victim )
		
		DropFlag( victim )
	}
}

void function CreateFlags()
{	
	if ( IsValid( file.imcFlagSpawn ) )
	{
		file.imcFlagSpawn.Destroy()
		file.imcFlag.Destroy()
		file.imcFlagReturnTrigger.Destroy()
		
		file.militiaFlagSpawn.Destroy()
		file.militiaFlag.Destroy()
		file.militiaFlagReturnTrigger.Destroy()
	}

	foreach ( entity spawn in GetEntArrayByClass_Expensive( "info_spawnpoint_flag" ) )
	{
		// on some maps flags are on the opposite side from what they should be
		// likely this is because respawn uses distance checks from spawns to check this in official
		// but i don't like doing that so just using a list of maps to swap them on lol
		bool switchedSides = HasSwitchedSides() == 1

		// i dont know why this works and whatever we had before didn't, but yeah
		bool shouldSwap = switchedSides 
		if (!shouldSwap && SWAP_FLAG_MAPS.contains( GetMapName() ))
			shouldSwap = !shouldSwap
		

		int flagTeam = spawn.GetTeam()
		if ( shouldSwap )
		{
			flagTeam = GetOtherTeam( flagTeam )
			SetTeam( spawn, flagTeam )
		}
	
		// create flag base
		entity base = CreatePropDynamic( CTF_FLAG_BASE_MODEL, spawn.GetOrigin(), spawn.GetAngles(), 0 )
		SetTeam( base, spawn.GetTeam() )
		svGlobal.flagSpawnPoints[ flagTeam ] = base
		
		// create flag
		entity flag = CreateEntity( "item_flag" )
		flag.SetValueForModelKey( CTF_FLAG_MODEL )
		SetTeam( flag, flagTeam )
		flag.MarkAsNonMovingAttachment()
		DispatchSpawn( flag )
		flag.SetModel( CTF_FLAG_MODEL )
		flag.SetOrigin( spawn.GetOrigin() + < 0, 0, base.GetBoundingMaxs().z * 2 > ) // ensure flag doesn't spawn clipped into geometry
		flag.SetVelocity( < 0, 0, 1 > )
		
		flag.s.canTake <- true
		flag.s.playersReturning <- []
		
		level.teamFlags[ flag.GetTeam() ] <- flag
			
		entity returnTrigger = CreateEntity( "trigger_cylinder" )
		SetTeam( returnTrigger, flagTeam )
		returnTrigger.SetRadius( CTF_GetFlagReturnRadius() )
		returnTrigger.SetAboveHeight( CTF_GetFlagReturnRadius() )
		returnTrigger.SetBelowHeight( CTF_GetFlagReturnRadius() )
		
		returnTrigger.SetEnterCallback( OnPlayerEntersFlagReturnTrigger )
		returnTrigger.SetLeaveCallback( OnPlayerExitsFlagReturnTrigger )
		
		DispatchSpawn( returnTrigger )
		
		thread TrackFlagReturnTrigger( flag, returnTrigger )
			
		if ( flagTeam == TEAM_IMC )
		{
			file.imcFlagSpawn = base
			file.imcFlag = flag
			file.imcFlagReturnTrigger = returnTrigger
			
			SetGlobalNetEnt( "imcFlag", file.imcFlag )
			SetGlobalNetEnt( "imcFlagHome", file.imcFlagSpawn )
		}
		else
		{
			file.militiaFlagSpawn = base
			file.militiaFlag = flag
			file.militiaFlagReturnTrigger = returnTrigger
			
			SetGlobalNetEnt( "milFlag", file.militiaFlag )
			SetGlobalNetEnt( "milFlagHome", file.militiaFlagSpawn )
		}
	}
	
	// reset the flag states, prevents issues where flag is home but doesnt think it's home when halftime goes
	SetFlagStateForTeam( TEAM_MILITIA, eFlagState.None )
	SetFlagStateForTeam( TEAM_IMC, eFlagState.None )
	
	foreach ( entity player in GetPlayerArray() )
		CTFInitPlayer( player )
}

void function RemoveFlags()
{
	// destroy all the flag related things
	if ( IsValid( file.imcFlagSpawn ) )
	{
		file.imcFlagSpawn.Destroy()
		file.imcFlag.Destroy()
		file.imcFlagReturnTrigger.Destroy()
	}
	if ( IsValid( file.militiaFlagSpawn ) )
	{
		file.militiaFlagSpawn.Destroy()
		file.militiaFlag.Destroy()
		file.militiaFlagReturnTrigger.Destroy()
	}

	// unsure if this is needed, since the flags are destroyed? idk
	SetFlagStateForTeam( TEAM_MILITIA, eFlagState.None )
	SetFlagStateForTeam( TEAM_IMC, eFlagState.None )
}

void function TrackFlagReturnTrigger( entity flag, entity returnTrigger )
{
	// this is a bit of a hack, it seems parenting the return trigger to the flag actually sets the pickup radius of the flag to be the same as the trigger
	// this isn't wanted since only pickups should use that additional radius
	flag.EndSignal( "OnDestroy" )
		
	while ( true )
	{
		returnTrigger.SetOrigin( flag.GetOrigin() )
		WaitFrame()
	}
}

void function SetFlagStateForTeam( int team, int state )
{
	if ( state == eFlagState.Away ) // we tell the client the flag is the player carrying it if they're carrying it
		SetGlobalNetEnt( team == TEAM_IMC ? "imcFlag" : "milFlag", ( team == TEAM_IMC ? file.imcFlag : file.militiaFlag ).GetParent() )
	else
		SetGlobalNetEnt( team == TEAM_IMC ? "imcFlag" : "milFlag", team == TEAM_IMC ? file.imcFlag : file.militiaFlag )

	SetGlobalNetInt( team == TEAM_IMC ? "imcFlagState" : "milFlagState", state )
}

bool function OnFlagCollected( entity player, entity flag )
{
	if ( !IsAlive( player ) || flag.GetParent() != null || player.IsTitan() || player.IsPhaseShifted() ) 
		return false

	if ( player.GetTeam() != flag.GetTeam() && flag.s.canTake )
		GiveFlag( player, flag ) // pickup enemy flag
	else if ( player.GetTeam() == flag.GetTeam() && IsFlagHome( flag ) && PlayerHasEnemyFlag( player ) )
		CaptureFlag( player, GetFlagForTeam( GetOtherTeam( flag.GetTeam() ) ) ) // cap the flag

	return false // don't wanna delete the flag entity
}

void function GiveFlag( entity player, entity flag )
{
	print( player + " picked up the flag!" )
	flag.Signal( "ResetDropTimeout" )

	flag.SetParent( player, "FLAG" )
	thread DropFlagIfPhased( player, flag )

	// do notifications
	MessageToPlayer( player, eEventNotifications.YouHaveTheEnemyFlag )
	EmitSoundOnEntityOnlyToPlayer( player, player, "UI_CTF_1P_GrabFlag" )
	AddPlayerScore( player, "FlagTaken", player )
	PlayFactionDialogueToPlayer( "ctf_flagPickupYou", player )
	
	MessageToTeam( player.GetTeam(), eEventNotifications.PlayerHasEnemyFlag, player, player )
	EmitSoundOnEntityToTeamExceptPlayer( flag, "UI_CTF_3P_TeamGrabFlag", player.GetTeam(), player )
	PlayFactionDialogueToTeamExceptPlayer( "ctf_flagPickupFriendly", player.GetTeam(), player )
	
	MessageToTeam( flag.GetTeam(), eEventNotifications.PlayerHasFriendlyFlag, player, player )
	EmitSoundOnEntityToTeam( flag, "UI_CTF_EnemyGrabFlag", flag.GetTeam() )
	
	SetFlagStateForTeam( flag.GetTeam(), eFlagState.Away ) // used for held
}

void function DropFlagIfPhased( entity player, entity flag )
{
	player.EndSignal( "StartPhaseShift" )
	player.EndSignal( "OnDestroy" )
	
	OnThreadEnd( function() : ( player ) 
	{
		if (GetGameState() == eGameState.Playing || GetGameState() == eGameState.SuddenDeath)
			DropFlag( player, true )
	})
	// the IsValid check is purely to prevent a crash due to a destroyed flag (epilogue)
	while( IsValid(flag) && flag.GetParent() == player )
		WaitFrame()
}

void function DropFlagForBecomingTitan( entity pilot, entity titan )
{
	DropFlag( pilot, true )
}

void function DropFlag( entity player, bool realDrop = true )
{
	entity flag = GetFlagForTeam( GetOtherTeam( player.GetTeam() ) )
	
	if ( flag.GetParent() != player )
		return
		
	print( player + " dropped the flag!" )
	
	flag.ClearParent()
	flag.SetAngles( < 0, 0, 0 > )
	flag.SetVelocity( < 0, 0, 0 > )
	
	if ( realDrop )
	{
		// start drop timeout countdown
		thread TrackFlagDropTimeout( flag )
	
		// add to capture assists
		if ( player.GetTeam() == TEAM_IMC )
			file.imcCaptureAssistList.append( player )
		else
			file.militiaCaptureAssistList.append( player )
	
		// do notifications
		MessageToPlayer( player, eEventNotifications.YouDroppedTheEnemyFlag )
		EmitSoundOnEntityOnlyToPlayer( player, player, "UI_CTF_1P_FlagDrop" )
		
		MessageToTeam( player.GetTeam(), eEventNotifications.PlayerDroppedEnemyFlag, player, player )
		// todo need a sound here maybe
		
		MessageToTeam( GetOtherTeam( player.GetTeam() ), eEventNotifications.PlayerDroppedFriendlyFlag, player, player )
		// todo need a sound here maybe
	}
	
	SetFlagStateForTeam( flag.GetTeam(), eFlagState.Home ) // used for return prompt
}

void function TrackFlagDropTimeout( entity flag )
{
	flag.EndSignal( "ResetDropTimeout" )
	
	wait CTF_GetDropTimeout()
	
	ResetFlag( flag )
}

void function ResetFlag( entity flag )
{
	// prevents crash when flag is reset after it's been destroyed due to epilogue
	if (!IsValid(flag))
		return
	// ensure we can't pickup the flag after it's been dropped but before it's been reset
	flag.s.canTake = false
	
	if ( flag.GetParent() != null )
		DropFlag( flag.GetParent(), false )
	
	entity spawn
	if ( flag.GetTeam() == TEAM_IMC )
		spawn = file.imcFlagSpawn
	else
		spawn = file.militiaFlagSpawn
		
	flag.SetOrigin( spawn.GetOrigin() + < 0, 0, spawn.GetBoundingMaxs().z + 1 > )
	
	// we can take it again now
	flag.s.canTake = true
	
	SetFlagStateForTeam( flag.GetTeam(), eFlagState.None ) // used for home
	
	flag.Signal( "ResetDropTimeout" )
}

void function CaptureFlag( entity player, entity flag )
{
	// can only capture flags during normal play or sudden death
	if (GetGameState() != eGameState.Playing && GetGameState() != eGameState.SuddenDeath)
	{
		printt( player + " tried to capture the flag, but the game state was " + GetGameState() + " not " + eGameState.Playing + " or " + eGameState.SuddenDeath)
		return
	}
	// reset flag
	ResetFlag( flag )
	
	print( player + " captured the flag!" )
	
	// score
	int team = player.GetTeam() 
	AddTeamScore( team, 1 )
	AddPlayerScore( player, "FlagCapture", player )
	player.AddToPlayerGameStat( PGS_ASSAULT_SCORE, 1 ) // add 1 to captures on scoreboard
	SetRoundWinningKillReplayAttacker( player ) // set attacker for last cap replay
	
	array<entity> assistList
	if ( player.GetTeam() == TEAM_IMC )
		assistList = file.imcCaptureAssistList
	else
		assistList = file.militiaCaptureAssistList
	
	foreach( entity assistPlayer in assistList )
		if ( player != assistPlayer )
			AddPlayerScore( assistPlayer, "FlagCaptureAssist", player )
		
	assistList.clear()
	
	// notifs
	MessageToPlayer( player, eEventNotifications.YouCapturedTheEnemyFlag )
	EmitSoundOnEntityOnlyToPlayer( player, player, "UI_CTF_1P_PlayerScore" )
	
	MessageToTeam( team, eEventNotifications.PlayerCapturedEnemyFlag, player, player )
	EmitSoundOnEntityToTeamExceptPlayer( flag, "UI_CTF_3P_TeamScore", player.GetTeam(), player )
	
	MessageToTeam( GetOtherTeam( team ), eEventNotifications.PlayerCapturedFriendlyFlag, player, player )
	EmitSoundOnEntityToTeam( flag, "UI_CTF_3P_EnemyScore", flag.GetTeam() )
	
	if ( GameRules_GetTeamScore( team ) == GameMode_GetRoundScoreLimit( GAMETYPE ) - 1 )
	{
		PlayFactionDialogueToTeam( "ctf_notifyWin1more", team )
		PlayFactionDialogueToTeam( "ctf_notifyLose1more", GetOtherTeam( team ) )
	}
}

void function OnPlayerEntersFlagReturnTrigger( entity trigger, entity player )
{
	entity flag
	if ( trigger.GetTeam() == TEAM_IMC )
		flag = file.imcFlag
	else
		flag = file.militiaFlag
	
	if ( !player.IsPlayer() || player.IsTitan() || player.GetTeam() != flag.GetTeam() || IsFlagHome( flag ) || flag.GetParent() != null )
		return
		
	thread TryReturnFlag( player, flag )
}

void function OnPlayerExitsFlagReturnTrigger( entity trigger, entity player )
{
	entity flag
	if ( trigger.GetTeam() == TEAM_IMC )
		flag = file.imcFlag
	else
		flag = file.militiaFlag
		
	if ( !player.IsPlayer() || player.IsTitan() || player.GetTeam() != flag.GetTeam() || IsFlagHome( flag ) || flag.GetParent() != null )
		return
	
	player.Signal( "FlagReturnEnded" )
}	

void function TryReturnFlag( entity player, entity flag )
{
	// start return progress bar
	Remote_CallFunction_NonReplay( player, "ServerCallback_CTF_StartReturnFlagProgressBar", Time() + CTF_GetFlagReturnTime() )
	EmitSoundOnEntityOnlyToPlayer( player, player, "UI_CTF_1P_FlagReturnMeter" )
	
	OnThreadEnd( function() : ( player )
	{
		// cleanup
		Remote_CallFunction_NonReplay( player, "ServerCallback_CTF_StopReturnFlagProgressBar" )
		StopSoundOnEntity( player, "UI_CTF_1P_FlagReturnMeter" )
	})
	
	player.EndSignal( "FlagReturnEnded" )
	player.EndSignal( "OnDeath" )
	
	wait CTF_GetFlagReturnTime()
	
	// flag return succeeded
	// return flag
	ResetFlag( flag )
	
	// do notifications for return
	MessageToPlayer( player, eEventNotifications.YouReturnedFriendlyFlag )
	AddPlayerScore( player, "FlagReturn", player )
	player.AddToPlayerGameStat( PGS_DEFENSE_SCORE, 1 )
	
	MessageToTeam( flag.GetTeam(), eEventNotifications.PlayerReturnedFriendlyFlag, null, player )
	EmitSoundOnEntityToTeam( flag, "UI_CTF_3P_TeamReturnsFlag", flag.GetTeam() )
	PlayFactionDialogueToTeam( "ctf_flagReturnedFriendly", flag.GetTeam() )
	
	MessageToTeam( GetOtherTeam( flag.GetTeam() ), eEventNotifications.PlayerReturnedEnemyFlag, null, player )
	EmitSoundOnEntityToTeam( flag, "UI_CTF_3P_EnemyReturnsFlag", GetOtherTeam( flag.GetTeam() ) )
	PlayFactionDialogueToTeam( "ctf_flagReturnedEnemy", GetOtherTeam( flag.GetTeam() ) )
}