#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <faceit-api>

#define PLUGIN_VERSION "1.0.0"

ConVar convar_Enabled;
ConVar convar_APIKey;

enum struct Player {
	bool registered;

	char player_id[128];
	int skill_level;
	int faceit_elo;

	void Clear() {
		this.registered = false;

		this.player_id[0] = '\0';
		this.skill_level = 0;
		this.faceit_elo = 0;
	}
}

Player g_Player[MAXPLAYERS + 1];

GlobalForward g_Forward_OnGetFACEITData;

public Plugin myinfo = {
	name = "[ANY] FACEIT - API",
	author = "Drixevel",
	description = "The main API plugin for FACEIT integration.",
	version = PLUGIN_VERSION,
	url = "https://drixevel.dev/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	RegPluginLibrary("faceit-api");

	CreateNative("FACEIT_IsRegistered", Native_IsRegistered);
	CreateNative("FACEIT_GetPlayerID", Native_GetPlayerID);
	CreateNative("FACEIT_GetSkillLevel", Native_GetSkillLevel);
	CreateNative("FACEIT_GetElo", Native_GetElo);

	g_Forward_OnGetFACEITData = new GlobalForward("OnGetFACEITData", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	return APLRes_Success;
}

public void OnPluginStart() {
	CreateConVar("sm_faceit_api_version", PLUGIN_VERSION, "Version control for this plugin.", FCVAR_DONTRECORD);
	convar_Enabled = CreateConVar("sm_faceit_api_enabled", "1", "Should this plugin be enabled or disabled?", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	convar_APIKey = CreateConVar("sm_faceit_api_key", "", "What's the API key?", FCVAR_PROTECTED);
	AutoExecConfig();
}

public void OnConfigsExecuted() {
	char auth[64];
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientAuthorized(i) && GetClientAuthId(i, AuthId_Engine, auth, sizeof(auth))) {
			OnClientAuthorized(i, auth);
		}
	}
}

public void OnClientAuthorized(int client, const char[] auth) {
	if (!convar_Enabled.BoolValue) {
		return;
	}

	if (IsFakeClient(client)) {
		return;
	}

	char steamid64[64];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64))) {
		return;
	}
	
	char apikey[64];
	convar_APIKey.GetString(apikey, sizeof(apikey));

	if (strlen(apikey) == 0) {
		ThrowError("[SM] Couldn't authorize FACEIT API request for %N: API key is empty.", client);
	}

	Format(apikey, sizeof(apikey), "Bearer %s", apikey);

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, "https://open.faceit.com/data/v4/players");
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(request, 10);

	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "game", "csgo");
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "game_player_id", steamid64);

	SteamWorks_SetHTTPRequestHeaderValue(request, "accept", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "Authorization", apikey);

	SteamWorks_SetHTTPCallbacks(request, OnGetFACEITAPIData);
	SteamWorks_SetHTTPRequestContextValue(request, GetClientUserId(client));
	SteamWorks_SendHTTPRequest(request);

	LogMessage("[SM] Requesting FACEIT data for %N...", client);
}

public void OnGetFACEITAPIData(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1)  {
	if (!convar_Enabled.BoolValue) {
		return;
	}

	//PrintToServer("Status: %i", eStatusCode);

	if (eStatusCode != k_EHTTPStatusCode200OK && eStatusCode != k_EHTTPStatusCode404NotFound) {
		ThrowError("[SM] Error while fetching FACEIT data with Error Code '%i'.", eStatusCode);
	}

	int client;
	if ((client = GetClientOfUserId(data1)) < 1) {
		return;
	}

	g_Player[client].registered = eStatusCode != k_EHTTPStatusCode404NotFound;

	int size;
	SteamWorks_GetHTTPResponseBodySize(hRequest, size);

	char[] body = new char[size];
	SteamWorks_GetHTTPResponseBodyData(hRequest, body, size);

	delete hRequest;

	JSON_Object obj = json_decode(body);

	if (obj != null) {
		if (obj.HasKey("player_id")) {
			obj.GetString("player_id", g_Player[client].player_id, sizeof(Player::player_id));
			//PrintToServer("[SM] Player ID: %s", g_Player[client].player_id);
		}

		if (obj.HasKey("games")) {
			JSON_Object games = obj.GetObject("games");
			
			if (games != null && games.HasKey("csgo")) {
				JSON_Object csgo = games.GetObject("csgo");
				
				if (csgo != null) {
					if (csgo.HasKey("skill_level")) {
						g_Player[client].skill_level = csgo.GetInt("skill_level");
						//PrintToServer("[SM] Skill Level: %i", g_Player[client].skill_level);
					}
					
					if (csgo.HasKey("faceit_elo")) {
						g_Player[client].faceit_elo = csgo.GetInt("faceit_elo");
						//PrintToServer("[SM] ELO: %i", g_Player[client].faceit_elo);
					}
				}
			}
		}
	}

	Call_StartForward(g_Forward_OnGetFACEITData);
	Call_PushCell(client);
	Call_PushCell(g_Player[client].registered);
	Call_PushCell(json_copy_deep(obj)); //Might need to duplicate this.
	Call_Finish();

	json_cleanup_and_delete(obj);

	LogMessage("[SM] Successfully fetched FACEIT data for %N, they %s registered.", client, g_Player[client].registered ? "are" : "are not");
}

public void OnClientDisconnect_Post(int client) {
	g_Player[client].Clear();
}

public int Native_IsRegistered(Handle plugin, int numParam) {
	if (!convar_Enabled.BoolValue) {
		return ThrowNativeError(SP_ERROR_NATIVE, "FACEIT API is disabled.");
	}

	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %i", client);
	}

	return g_Player[client].registered;
}

public int Native_GetPlayerID(Handle plugin, int numParam) {
	if (!convar_Enabled.BoolValue) {
		return ThrowNativeError(SP_ERROR_NATIVE, "FACEIT API is disabled.");
	}

	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %i", client);
	}
 
	SetNativeString(2, g_Player[client].player_id, sizeof(Player::player_id));
	return 1;
}

public int Native_GetSkillLevel(Handle plugin, int numParam) {
	if (!convar_Enabled.BoolValue) {
		return ThrowNativeError(SP_ERROR_NATIVE, "FACEIT API is disabled.");
	}

	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %i", client);
	}

	return g_Player[client].skill_level;
}

public int Native_GetElo(Handle plugin, int numParam) {
	if (!convar_Enabled.BoolValue) {
		return ThrowNativeError(SP_ERROR_NATIVE, "FACEIT API is disabled.");
	}
	
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %i", client);
	}

	return g_Player[client].faceit_elo;
}