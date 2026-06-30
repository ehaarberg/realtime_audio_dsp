import csv, numpy as np, matplotlib.pyplot as plt; from matplotlib.ticker import FuncFormatter; from pathlib import Path
meas_path=Path('analysis/RigolDS1.csv'); pred_path=Path('analysis/plots/dsp_response_data.csv'); out_plot=Path('analysis/plots/t05_gain_measured_vs_predicted.png')
# measured
freq=[]; gain=[]
with meas_path.open(encoding='utf-8-sig') as f:
    r=csv.reader(f)
    for row in r:
        if len(row)>=3:
            try:
                fr=float(row[0]); ga=float(row[1]); freq.append(fr); gain.append(ga)
            except: pass
freq=np.array(freq); gain=np.array(gain)
# predicted
with pred_path.open(encoding='utf-8-sig') as f:
    dr=csv.DictReader(f); rows=list(dr)
pf=np.array([float(r['frequency_hz']) for r in rows]); pg=np.array([float(r['crossover_sum_only_mag_db']) for r in rows])
plt.figure(figsize=(8.3,5.0))
plt.semilogx(pf, pg, label='Predicted crossover gain', linewidth=2)
plt.semilogx(freq, gain, 'o-', label='Measured gain', markersize=3, linewidth=1)
xt=[20,50,100,200,500,1000,2000,4500,8000,20000]
plt.xticks(xt)
plt.gca().xaxis.set_major_formatter(FuncFormatter(lambda x,pos: f'{int(x):d}' if x>=1 else f'{x:g}'))
plt.xlim(20,20000)
plt.ylim(-40, 10)
plt.xlabel('Frequency (Hz)')
plt.ylabel('Gain (dB)')
plt.title('Crossover Gain Response (alpha=0)')
plt.grid(True, which='both', alpha=0.3)
plt.legend()
plt.tight_layout()
out_plot.parent.mkdir(parents=True, exist_ok=True)
plt.savefig(out_plot, dpi=170)
print(out_plot)