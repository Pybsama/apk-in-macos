package dev.apkinmacos.sketchnotes;

import android.app.Activity;
import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private TextView meta;
    private PadView pad;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#1D1B18"));
        root.setPadding(24, 30, 24, 24);

        TextView title = new TextView(this);
        title.setText("Sketch Notes");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(Color.parseColor("#FAF7F0"));
        root.addView(title);

        meta = new TextView(this);
        meta.setTextSize(12);
        meta.setTextColor(Color.parseColor("#ABA294"));
        meta.setPadding(0, 4, 0, 14);
        root.addView(meta);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(0, 0, 0, 14);
        root.addView(bar);

        int[] palette = {
                Color.parseColor("#E3B261"),
                Color.parseColor("#6BBF8A"),
                Color.parseColor("#6EA8E5"),
                Color.parseColor("#E2857E")
        };
        for (int c : palette) {
            Button sw = new Button(this);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(c);
            bg.setCornerRadius(999);
            sw.setBackground(bg);
            sw.setOnClickListener(v -> pad.setColor(c));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(54, 42);
            lp.setMargins(0, 0, 12, 0);
            bar.addView(sw, lp);
        }

        Button clear = new Button(this);
        clear.setText("Clear");
        clear.setAllCaps(false);
        clear.setTextColor(Color.parseColor("#FAF7F0"));
        GradientDrawable cbg = new GradientDrawable();
        cbg.setColor(Color.parseColor("#35312C"));
        cbg.setCornerRadius(999);
        clear.setBackground(cbg);
        clear.setOnClickListener(v -> pad.clear());
        bar.addView(clear);

        pad = new PadView(this);
        GradientDrawable pbg = new GradientDrawable();
        pbg.setColor(Color.parseColor("#272420"));
        pbg.setCornerRadius(22);
        pbg.setStroke(2, Color.parseColor("#3B3630"));
        pad.setBackground(pbg);
        root.addView(pad, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        refreshMeta();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        refreshMeta();
    }

    private void refreshMeta() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        int id = (getDisplay() != null) ? getDisplay().getDisplayId() : -1;
        meta.setText("Display #" + id + " · " + dm.widthPixels + "×" + dm.heightPixels + " · " + dm.densityDpi + "dpi");
    }

    private static final class Stroke {
        final Path path = new Path();
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        Stroke(int color) {
            paint.setColor(color);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(7f);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }
    }

    private static final class PadView extends View {
        private final List<Stroke> strokes = new ArrayList<>();
        private Stroke active;
        private int color = Color.parseColor("#E3B261");

        PadView(Context ctx) { super(ctx); }
        void setColor(int c) { color = c; }
        void clear() { strokes.clear(); active = null; invalidate(); }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            float x = e.getX(), y = e.getY();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    active = new Stroke(color);
                    active.path.moveTo(x, y);
                    strokes.add(active);
                    invalidate();
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (active != null) { active.path.lineTo(x, y); invalidate(); }
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    active = null;
                    invalidate();
                    return true;
                default:
                    return super.onTouchEvent(e);
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            for (Stroke s : strokes) canvas.drawPath(s.path, s.paint);
        }
    }
}
