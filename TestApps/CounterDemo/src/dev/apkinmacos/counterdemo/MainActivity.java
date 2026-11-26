package dev.apkinmacos.counterdemo;

import android.app.Activity;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public class MainActivity extends Activity {
    private int count = 0;
    private TextView countLabel;
    private TextView metricsLabel;
    private TextView echoLabel;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Color.parseColor("#FAF7F0"));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(36, 42, 36, 42);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Counter Demo");
        title.setTextSize(24);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(Color.parseColor("#28241F"));
        root.addView(title);

        metricsLabel = new TextView(this);
        metricsLabel.setTextSize(12);
        metricsLabel.setTextColor(Color.parseColor("#7C7468"));
        metricsLabel.setPadding(0, 6, 0, 20);
        root.addView(metricsLabel);

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(32, 32, 32, 32);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.parseColor("#FFFDF8"));
        bg.setCornerRadius(24);
        bg.setStroke(2, Color.parseColor("#E8E0D0"));
        card.setBackground(bg);
        LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        cardLp.setMargins(0, 0, 0, 20);
        root.addView(card, cardLp);

        countLabel = new TextView(this);
        countLabel.setText("0");
        countLabel.setTextSize(60);
        countLabel.setTypeface(Typeface.DEFAULT_BOLD);
        countLabel.setTextColor(Color.parseColor("#28241F"));
        card.addView(countLabel);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER);
        row.setPadding(0, 18, 0, 0);
        card.addView(row);

        Button dec = pill("- 1", "#F2EEE4", "#28241F");
        dec.setOnClickListener(v -> setCount(count - 1));
        row.addView(dec, margin(10));

        Button reset = pill("Reset", "#F5E7CE", "#7C5319");
        reset.setOnClickListener(v -> setCount(0));
        row.addView(reset, margin(10));

        Button inc = pill("+ 1", "#2C2722", "#FFFDF8");
        inc.setOnClickListener(v -> setCount(count + 1));
        row.addView(inc, margin(10));

        EditText input = new EditText(this);
        input.setHint("Type or paste text...");
        input.setTextColor(Color.parseColor("#28241F"));
        input.setHintTextColor(Color.parseColor("#ABA294"));
        input.setPadding(22, 18, 22, 18);
        GradientDrawable inBg = new GradientDrawable();
        inBg.setColor(Color.parseColor("#FFFDF8"));
        inBg.setCornerRadius(16);
        inBg.setStroke(2, Color.parseColor("#E8E0D0"));
        input.setBackground(inBg);
        LinearLayout.LayoutParams inLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        inLp.setMargins(0, 0, 0, 14);
        root.addView(input, inLp);

        Button submit = pill("Echo Text", "#4E8C62", "#FFFDF8");
        submit.setOnClickListener(v -> echoLabel.setText("Input: " + input.getText().toString()));
        root.addView(submit);

        echoLabel = new TextView(this);
        echoLabel.setText("Touch, scroll, keyboard & resize ready");
        echoLabel.setTextSize(13);
        echoLabel.setTextColor(Color.parseColor("#7C7468"));
        echoLabel.setPadding(0, 18, 0, 14);
        root.addView(echoLabel);

        setContentView(scroll);
        refreshMetrics();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        refreshMetrics();
    }

    private void setCount(int n) {
        count = n;
        countLabel.setText(String.valueOf(count));
    }

    private void refreshMetrics() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        int id = (getDisplay() != null) ? getDisplay().getDisplayId() : -1;
        metricsLabel.setText("Display #" + id + " · " + dm.widthPixels + "×" + dm.heightPixels + " · " + dm.densityDpi + "dpi");
    }

    private Button pill(String text, String bgHex, String fgHex) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(15);
        b.setTextColor(Color.parseColor(fgHex));
        b.setPadding(26, 14, 26, 14);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.parseColor(bgHex));
        bg.setCornerRadius(999);
        b.setBackground(bg);
        return b;
    }

    private LinearLayout.LayoutParams margin(int m) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(m, 0, m, 0);
        return lp;
    }
}
