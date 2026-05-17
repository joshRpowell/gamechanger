// Package parser converts the Gamechanger boxscore response into typed
// rows that the storage layer can persist.
//
// Boxscore response shape (per team_slug):
//
//	{
//	  "{team_slug}": {
//	    "players": [{ "id", "first_name", "last_name", "number" }],
//	    "groups": [
//	      { "category": "pitching",
//	        "extra": [
//	          { "stat_name": "#P", "stats": [{"player_id","value"}] },
//	          { "stat_name": "TS", "stats": [...] }
//	        ],
//	        "stats": [{"player_id", "stats": {"IP","H","R","ER","BB","SO"}}]
//	      },
//	      { "category": "lineup",
//	        "stats": [{"player_id", "stats": {"AB","H","BB","K"}}]
//	      }
//	    ]
//	  }
//	}
package parser

import (
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// PitcherStats returns one row per pitcher who threw at least one pitch.
// Empty slice (not error) if the pitching group is absent or empty.
func PitcherStats(response map[string]any, teamSlug string) ([]store.PitcherStat, error) {
	teamData, err := teamData(response, teamSlug)
	if err != nil {
		return nil, err
	}
	pitching := findGroup(teamData, "pitching")
	if pitching == nil {
		return nil, nil
	}
	players := playerIndex(teamData)

	pitchCounts := extractExtra(pitching, "#P")
	strikes := indexExtra(pitching, "TS")
	innings := innesPitchedIndex(pitching)

	out := make([]store.PitcherStat, 0, len(pitchCounts))
	for _, entry := range pitchCounts {
		entryMap, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		pid, _ := entryMap["player_id"].(string)
		player, ok := players[pid]
		if !ok {
			continue
		}
		row := store.PitcherStat{
			PitcherName:   playerName(player),
			PitchesThrown: toInt(entryMap["value"]),
		}
		if v, ok := strikes[pid]; ok {
			row.StrikesThrown.Int64 = int64(v)
			row.StrikesThrown.Valid = true
		}
		if v, ok := innings[pid]; ok {
			row.InningsPitched.Float64 = v
			row.InningsPitched.Valid = true
		}
		out = append(out, row)
	}
	return out, nil
}

// BatterStats returns one row per player in the lineup group. Empty slice
// (not error) if the lineup group is absent or empty.
func BatterStats(response map[string]any, teamSlug string) ([]store.BatterStat, error) {
	teamData, err := teamData(response, teamSlug)
	if err != nil {
		return nil, err
	}
	lineup := findGroup(teamData, "lineup")
	if lineup == nil {
		return nil, nil
	}
	players := playerIndex(teamData)

	statsList, _ := lineup["stats"].([]any)
	out := make([]store.BatterStat, 0, len(statsList))
	for _, row := range statsList {
		rowMap, ok := row.(map[string]any)
		if !ok {
			continue
		}
		pid, _ := rowMap["player_id"].(string)
		player, ok := players[pid]
		if !ok {
			continue
		}
		statMap, _ := rowMap["stats"].(map[string]any)
		out = append(out, store.BatterStat{
			BatterName: playerName(player),
			AtBats:     toInt(statMap["AB"]),
			Hits:       toInt(statMap["H"]),
			Walks:      toInt(statMap["BB"]),
			Strikeouts: toInt(statMap["K"]),
		})
	}
	return out, nil
}

func teamData(response map[string]any, teamSlug string) (map[string]any, error) {
	d, ok := response[teamSlug].(map[string]any)
	if !ok {
		return nil, gcerr.APIShapef("team %q not found in boxscore response", teamSlug)
	}
	return d, nil
}

func playerIndex(team map[string]any) map[string]map[string]any {
	idx := map[string]map[string]any{}
	players, _ := team["players"].([]any)
	for _, p := range players {
		pm, ok := p.(map[string]any)
		if !ok {
			continue
		}
		id, _ := pm["id"].(string)
		if id != "" {
			idx[id] = pm
		}
	}
	return idx
}

func findGroup(team map[string]any, category string) map[string]any {
	groups, _ := team["groups"].([]any)
	for _, g := range groups {
		gm, ok := g.(map[string]any)
		if !ok {
			continue
		}
		if cat, _ := gm["category"].(string); cat == category {
			return gm
		}
	}
	return nil
}

func extractExtra(group map[string]any, statName string) []any {
	extras, _ := group["extra"].([]any)
	for _, e := range extras {
		em, ok := e.(map[string]any)
		if !ok {
			continue
		}
		if sn, _ := em["stat_name"].(string); sn == statName {
			stats, _ := em["stats"].([]any)
			return stats
		}
	}
	return nil
}

func indexExtra(group map[string]any, statName string) map[string]int {
	out := map[string]int{}
	for _, e := range extractExtra(group, statName) {
		em, ok := e.(map[string]any)
		if !ok {
			continue
		}
		pid, _ := em["player_id"].(string)
		if pid != "" {
			out[pid] = toInt(em["value"])
		}
	}
	return out
}

func innesPitchedIndex(group map[string]any) map[string]float64 {
	out := map[string]float64{}
	stats, _ := group["stats"].([]any)
	for _, s := range stats {
		sm, ok := s.(map[string]any)
		if !ok {
			continue
		}
		pid, _ := sm["player_id"].(string)
		inner, _ := sm["stats"].(map[string]any)
		if ip, ok := inner["IP"]; ok && pid != "" {
			out[pid] = toFloat(ip)
		}
	}
	return out
}

func playerName(p map[string]any) string {
	first, _ := p["first_name"].(string)
	last, _ := p["last_name"].(string)
	name := first
	if name != "" && last != "" {
		name += " "
	}
	name += last
	return name
}

// toInt coerces a JSON number-or-string into an int. JSON's float64 default
// for numbers becomes int via truncation. Strings are parsed if numeric.
func toInt(v any) int {
	switch n := v.(type) {
	case nil:
		return 0
	case float64:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	case string:
		var out int
		// Accept simple integer strings; ignore parse errors (return 0).
		for _, c := range n {
			if c < '0' || c > '9' {
				return 0
			}
			out = out*10 + int(c-'0')
		}
		return out
	}
	return 0
}

func toFloat(v any) float64 {
	switch n := v.(type) {
	case nil:
		return 0
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	}
	return 0
}
