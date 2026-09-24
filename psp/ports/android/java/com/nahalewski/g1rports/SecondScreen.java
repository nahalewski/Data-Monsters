package com.nahalewski.g1rports;

import android.app.Presentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.view.Display;
import android.view.MotionEvent;
import android.view.View;

/**
 * The runtime's bottom half (touch pad, MODS and MENU panels) on a second
 * display: pulled from the native side ~30 times a second and drawn scaled
 * to the display; touches go back as logical bottom-half coordinates.
 */
public class SecondScreen extends Presentation {
  private static final int W = 480;
  private int H = 272;
  private int[] pixels = new int[W * H];
  private Bitmap bitmap = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888);
  private final Handler handler = new Handler();
  private View view;
  private final Rect dst = new Rect();

  public SecondScreen(Context ctx, Display display) { super(ctx, display); }

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    view = new View(getContext()) {
      final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
      @Override
      protected void onDraw(Canvas c) {
        c.drawColor(0xff101014);
        float s = Math.min(getWidth() / (float) W, getHeight() / (float) H);
        int dw = (int) (W * s), dh = (int) (H * s);
        int ox = (getWidth() - dw) / 2, oy = (getHeight() - dh) / 2;
        dst.set(ox, oy, ox + dw, oy + dh);
        c.drawBitmap(bitmap, null, dst, paint);
      }
      @Override
      public boolean onTouchEvent(MotionEvent e) {
        float s = Math.min(getWidth() / (float) W, getHeight() / (float) H);
        int dw = (int) (W * s), dh = (int) (H * s);
        int ox = (getWidth() - dw) / 2, oy = (getHeight() - dh) / 2;
        int action = e.getActionMasked();
        for (int i = 0; i < e.getPointerCount(); i++) {
          int id = e.getPointerId(i);
          float lx = (e.getX(i) - ox) / s, ly = (e.getY(i) - oy) / s + MainActivity.nativeTopHeight(); // below the top half
          boolean down = !(action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL
              || (action == MotionEvent.ACTION_POINTER_UP && e.getActionIndex() == i));
          MainActivity.nativeTouch(2000 + id, down ? 1 : 0, lx, ly);
        }
        return true;
      }
    };
    setContentView(view);
    handler.post(tick);
  }

  private final Runnable tick = new Runnable() {
    public void run() {
      int h = MainActivity.nativeBottomHeight();
      if (h != H && h > 0) {
        H = h;
        pixels = new int[W * H];
        bitmap = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888);
      }
      if (MainActivity.nativeGetBottomScreen(pixels, W, H)) {
        bitmap.setPixels(pixels, 0, W, 0, 0, W, H);
        if (view != null) view.invalidate();
      }
      handler.postDelayed(this, 33);
    }
  };

  @Override
  protected void onStop() {
    handler.removeCallbacks(tick);
    super.onStop();
  }
}
