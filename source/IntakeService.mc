import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

// Optional calorie deficit mode only (docs/deficit-mode.md): runs in the background every 15 minutes, fetches today's
// food intake from your server (Secrets.INTAKE_URL) through the phone, and hands it to the app's onBackgroundData(),
// which stores it for the face. The record also carries recent days' totals for the streak.
(:background)
class IntakeService extends System.ServiceDelegate {

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        Communications.makeWebRequest(Secrets.INTAKE_URL, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => {"Authorization" => "Bearer " + Secrets.READ_TOKEN},
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onResponse));
    }

    // Expected body: {"date": "2026-11-07", "in": 1300, "bmr": 1850, "ts": 1762526400}
    // 404 = nothing stored on the server: replace the watch's copy with an empty record so it shows "—" rather than
    // an old value. Any other failure (no phone, timeout): exit with null and keep the last good value.
    function onResponse(code as Number, data as Dictionary or String or Null) as Void {
        if (code == 200 && data instanceof Dictionary) {
            Background.exit(data as Dictionary<Application.PropertyKeyType, Application.PropertyValueType>);
        } else if (code == 404) {
            Background.exit({} as Dictionary<Application.PropertyKeyType, Application.PropertyValueType>);
        } else {
            Background.exit(null);
        }
    }
}
