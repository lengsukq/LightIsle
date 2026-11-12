package system

import "testing"

func TestParsePmsetBatt(t *testing.T) {
	t.Run("desktop mac mini ac only", func(t *testing.T) {
		st := ParsePmsetBatt("Now drawing from 'AC Power'\n")
		if !st.Available || st.OnBattery || st.UPSPresent || st.Source != "ac" {
			t.Fatalf("unexpected desktop AC status: %+v", st)
		}
	})

	t.Run("usb ups on ac power", func(t *testing.T) {
		raw := "Now drawing from 'AC Power'\n -Back-UPS ES 650G2 (id=12345)\t100%; charged; 0:00 remaining present: true\n"
		st := ParsePmsetBatt(raw)
		if !st.Available || st.OnBattery || !st.UPSPresent || st.DeviceName != "Back-UPS ES 650G2" {
			t.Fatalf("unexpected UPS AC status: %+v", st)
		}
		if st.Percent == nil || *st.Percent != 100 || st.LowBattery {
			t.Fatalf("unexpected UPS percent: %+v", st)
		}
	})

	t.Run("usb ups power outage discharging", func(t *testing.T) {
		raw := "Now drawing from 'UPS Power'\n -Santak TG-BOX 850 (id=99)\t68%; discharging; 0:24 remaining present: true\n"
		st := ParsePmsetBatt(raw)
		if !st.OnBattery || !st.UPSPresent || st.LowBattery {
			t.Fatalf("expected onBattery without lowBattery: %+v", st)
		}
		if st.RemainingMinutes == nil || *st.RemainingMinutes != 24 {
			t.Fatalf("unexpected remaining minutes: %+v", st)
		}
	})

	t.Run("low battery critical threshold", func(t *testing.T) {
		raw := "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t19%; discharging; 0:18 remaining present: true\n"
		st := ParsePmsetBatt(raw)
		if !st.OnBattery || !st.LowBattery {
			t.Fatalf("expected critical lowBattery: %+v", st)
		}
	})
}
