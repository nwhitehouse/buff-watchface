import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// The Buff watch face. The background fetch (IntakeService) only runs in the optional calorie deficit mode.
(:background)
class BuffApp extends Application.AppBase {

    // Started by the watch's own editor (Customize) to preview choices, not as the running face.
    private var _editMode as Boolean = false;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        if (state != null && state[:launchedFromWatchFaceSettingsEditor] == true) {
            _editMode = true;
        }
    }

    // Foreground only: never runs in the background process, which does not load the views, so the
    // background-scope type check is switched off for it.
    (:typecheck(false))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        // Deficit mode only (source/Secrets.mc): fetch today's food intake (and recent days') every 15 minutes.
        if (Secrets.INTAKE_URL.length() > 0 && !_editMode) {
            Background.registerForTemporalEvent(new Time.Duration(15 * 60));
        }
        var view = new BuffView();
        // In the editor, a delegate passes each choice (colour, what each arc tracks) back to the view.
        return _editMode ? [view, new BuffConfigDelegate(view)] : [view];
    }

    function getServiceDelegate() as [System.ServiceDelegate] {
        return [new IntakeService()];
    }

    // Intake fetched by IntakeService. Null (failed fetch) keeps the last good value.
    function onBackgroundData(data as Application.PersistableType) as Void {
        if (data instanceof Dictionary) {
            Application.Storage.setValue("intake", data as Dictionary<Application.Storage.KeyType, Application.Storage.ValueType>);
            Refresh.pending = true;
            WatchUi.requestUpdate();
        }
    }

    function onSettingsChanged() as Void {
        Refresh.pending = true;
        WatchUi.requestUpdate();
    }
}

// Set when new intake arrives or settings change, so the view re-reads its data and redraws now, not next minute.
// (:background) only because BuffApp is.
(:background)
module Refresh {
    var pending as Boolean = false;
}
