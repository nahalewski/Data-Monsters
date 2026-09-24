package com.nahalewski.g1rports;

import android.content.Context;
import android.content.res.Configuration;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Bundle;
import android.view.Display;

import org.libsdl.app.SDLActivity;

/**
 * gen1recomp for Android: the lovepsp runtime under SDL2.
 *
 * Screen layout is decided here and pushed to the runtime:
 *  - a second display (dual-screen phones, an external screen) shows the
 *    runtime's bottom half (touch pad, panels) through {@link SecondScreen};
 *  - a foldable held half-open in landscape (hinge angle sensor) switches
 *    the runtime to its DS layout: the game on the upper half, the controls
 *    on the lower half;
 *  - otherwise the single-screen touch layout.
 * The launcher's "Screen layout" option can override AUTO with SINGLE or DS.
 */
public class MainActivity extends SDLActivity implements SensorEventListener {
  static { System.loadLibrary("SDL2"); System.loadLibrary("main"); }

  public static native void nativeSetLayout(int mode); // 0 single, 1 ds, 2 dual (second screen)
  public static native void nativeSetTouch(int on);
  public static native boolean nativeGetBottomScreen(int[] pixels, int w, int h);
  public static native void nativeTouch(int id, int down, float lx, float ly);
  public static native void nativeSetHinge(float degrees);
  public static native int nativeBottomHeight();
  public static native int nativeTopHeight();

  /** called from the runtime: open a page (the port's release page for updates) */
  public void openUrl(String url) {
    try {
      android.content.Intent i = new android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url));
      i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
      startActivity(i);
    } catch (Exception e) {
      android.util.Log.w("lovepsp", "openUrl: " + e);
    }
  }

  private SensorManager sensors;
  private Sensor hinge;
  private DisplayManager displays;
  private SecondScreen second;
  private float lastHinge = -1;

  @Override
  protected String[] getLibraries() { return new String[] { "SDL2", "main" }; }

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    sensors = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
    if (Build.VERSION.SDK_INT >= 30) hinge = sensors.getDefaultSensor(Sensor.TYPE_HINGE_ANGLE);
    displays = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
    displays.registerDisplayListener(displayListener, null);
  }

  @Override
  protected void onResume() {
    super.onResume();
    if (hinge != null) sensors.registerListener(this, hinge, SensorManager.SENSOR_DELAY_NORMAL);
    reportFoldState();
    updateSecondScreen();
    applyLayout();
  }

  @Override
  protected void onPause() {
    if (hinge != null) sensors.unregisterListener(this);
    super.onPause();
  }

  @Override
  public void onConfigurationChanged(Configuration c) {
    super.onConfigurationChanged(c);
    reportFoldState();
    applyLayout();
  }

  /** Without a hinge sensor the display tells: the cover screen of a
   *  foldable is phone-sized (under 600 dp on its short side), the inner
   *  screen tablet-sized.  Reported as a hinge angle (0 closed, 180 open). */
  private void reportFoldState() {
    if (hinge != null) return;
    int sw = getResources().getConfiguration().smallestScreenWidthDp;
    nativeSetHinge(sw > 0 && sw < 600 ? 0f : 180f);
  }

  @Override
  public void onSensorChanged(SensorEvent e) {
    if (e.sensor.getType() == Sensor.TYPE_HINGE_ANGLE) {
      float a = e.values[0];
      nativeSetHinge(a);
      if (lastHinge < 0 || Math.abs(a - lastHinge) > 5) { lastHinge = a; applyLayout(); }
    }
  }

  @Override
  public void onAccuracyChanged(Sensor s, int a) {}

  private final DisplayManager.DisplayListener displayListener = new DisplayManager.DisplayListener() {
    public void onDisplayAdded(int id) { runOnUiThread(() -> { updateSecondScreen(); applyLayout(); }); }
    public void onDisplayRemoved(int id) { runOnUiThread(() -> { updateSecondScreen(); applyLayout(); }); }
    public void onDisplayChanged(int id) {}
  };

  private Display findSecondDisplay() {
    Display[] all = displays.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
    return all.length > 0 ? all[0] : null;
  }

  private void updateSecondScreen() {
    Display d = findSecondDisplay();
    if (d != null && second == null) {
      second = new SecondScreen(this, d);
      second.show();
    } else if (d == null && second != null) {
      second.dismiss();
      second = null;
    }
  }

  /** half-open foldable in landscape: the lower half becomes the control surface */
  private boolean foldedLandscape() {
    if (lastHinge < 0) return false;
    boolean landscape = getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
    return landscape && lastHinge > 30 && lastHinge < 160;
  }

  /** the Fold app: always the DS layout (top screen game, bottom screen the
   *  3DS shell) whatever the hinge says; a second display takes the bottom half */
  private void applyLayout() {
    int mode = 1;
    if (second != null) mode = 2;
    nativeSetLayout(mode);
  }
}
