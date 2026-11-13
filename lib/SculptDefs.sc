// SculptDefs : les SynthDefs de sculpt, sans état.
SculptDefs {
	*add {
		// Lecteur de sample : lit tout le buffer en boucle.
		//   play  : 1 lecture (fondu de 1 ms, pour garder l'attaque du sample),
		//           0 arrêt (fondu de 10 ms) ; t_reset repart du début
		//   speed : vitesse (1 = normale), corrigée du taux du fichier
		// Un fondu de 5 ms à chaque bout évite le clic au raccord de boucle.
		// La position (0..1) part vers sclang 30 fois par seconde.
		SynthDef(\sculpt_player, { |out, buf, play = 0, speed = 1, level = 1, t_reset = 0|
			var frames = BufFrames.kr(buf);
			var gate = play > 0;
			var rate = BufRateScale.kr(buf) * speed * gate;
			var phase = Phasor.ar(T2A.ar(t_reset), rate, 0, frames, 0);
			var sig = BufRd.ar(2, buf, phase, 1, 4);
			var edge = (min(phase, frames - phase) / (0.005 * SampleRate.ir)).clip(0, 1);
			var amp = LagUD.kr(gate, 0.001, 0.01) * Lag.kr(level, 0.05);
			SendReply.kr(Impulse.kr(30), '/sculpt/pos', A2K.kr(phase) / frames);
			Out.ar(out, sig * edge * amp);
		}).add;

		// MOSAIC : granulaire sur les 4 dernières secondes du flux.
		// Le flux est enregistré en boucle dans bufL / bufR (un buffer mono
		// par côté), et des grains y sont relus.
		//   pitch    : hauteur des grains, en demi-tons
		//   rate     : cadence, en grains par seconde
		//   size     : durée d'un grain, en secondes
		//   contour  : forme du grain, -1 percussif .. 0 cloche .. +1 montée
		//   scan     : 0..1. scanMode 0 : retard derrière l'écriture (0..3,5 s) ;
		//              scanMode 1 : position fixe dans le buffer
		//   spray    : dispersion aléatoire de la position, tirée à part pour
		//              chaque côté, ce qui élargit la stéréo
		//   feedback : part de la sortie des grains réinjectée dans le buffer
		//   wet      : 0 direct seul .. 1 grains seuls
		//   lock     : 1 = le buffer n'est plus écrit
		//   bypass   : 1 = le direct seul (fondu de 20 ms)
		SynthDef(\sculpt_mosaic, { |bus, bufL, bufR, envBase, envSteps = 9, bypass = 0, lock = 0,
			pitch = 0, rate = 8, size = 0.15, contour = 0, scan = 0.1, scanMode = 0,
			spray = 0.1, feedback = 0, wet = 0.5|
			var in = In.ar(bus, 2);
			var sr = SampleRate.ir;
			var frames = BufFrames.kr(bufL);
			var bufDur = frames / sr;
			var run = 1 - lock;
			// la tête d'écriture : avance avec RecordBuf, s'arrête avec lui
			var wphase = Phasor.ar(0, run, 0, frames);
			var fb = LocalIn.ar(2);
			var ratio = pitch.midiratio;
			// au plus 48 grains à la fois par côté, pour borner le CPU
			var dur = min(size, 48 / rate);
			var trig = Impulse.ar(rate);
			// Un grain lu plus vite que l'écriture la rattraperait : le retard
			// minimal en tient compte. Le maximal laisse le grain finir avant
			// que l'écriture, qui a fait le tour, ne le rejoigne.
			var minD = (dur * max(ratio - 1, 0)) + 0.01;
			var maxD = bufDur - dur - 0.05;
			// SPRAY couvre tout ce que le buffer laisse disponible. La course
			// est élevée au carré : ses premiers degrés valent quelques
			// millisecondes, de quoi défaire l'addition en phase des grains,
			// et le haut de la course balaie le buffer entier.
			var sprayAmt = spray.squared;
			var scanD = (scan * 3.5).clip(minD, maxD);
			// en delay, l'étendue est ce qui reste derrière le point de scan :
			// au-delà, les grains s'entasseraient tous sur la borne
			var spreadDelay = (maxD - scanD) * sprayAmt;
			var spread = Select.kr(scanMode, [spreadDelay, bufDur * sprayAmt]);
			var env = envBase + ((contour + 1) * 0.5 * (envSteps - 1)).round;
			// Les grains se superposent : on ramène le niveau vers celui de
			// l'entrée. En général leurs ondes se mélangent au hasard, et le
			// niveau monte comme la racine de leur nombre (0,375 = puissance
			// moyenne d'une enveloppe). Mais sans dispersion et à hauteur 0, ils
			// relisent le même son en phase et s'additionnent pleinement (0,5 =
			// valeur moyenne d'une enveloppe). Entre les deux, la part en phase
			// dépend de l'étendue de SPRAY. Des grains clairsemés gardent leur
			// niveau.
			var n = rate * dur;
			// Ce qui décide, c'est l'étendue rapportée à la taille du grain :
			// des grains dispersés sur bien moins que leur propre durée lisent
			// presque le même segment et s'additionnent en phase. Le 45 est
			// mesuré au bruit rose. Un grain transposé se décorrèle tout seul.
			var inPhase = (1 + (45 * spread / dur)).reciprocal * (1 - pitch.abs).clip(0, 1);
			var norm = (((n * 0.375).sqrt * (1 - inPhase)) + (n * 0.5 * inPhase)).max(1).reciprocal;
			var grains = [bufL, bufR].collect { |b|
				var d = (scanD + (TRand.ar(0, 1, trig) * spreadDelay)).clip(minD, maxD);
				var posDelay = ((wphase / sr) - d) / bufDur;
				// en position, la lecture fait le tour du buffer : à fond,
				// SPRAY le couvre en entier sans se heurter à une borne
				var posFixed = scan + (TRand.ar(-0.5, 0.5, trig) * sprayAmt);
				var pos = Select.ar(K2A.ar(scanMode), [posDelay, posFixed]).wrap(0, 1);
				GrainBuf.ar(1, trig, dur, b, ratio, pos, 4, 0, env, 64);
			} * norm;
			var mix = Lag.kr(1 - bypass, 0.02);
			var w = Lag.kr(wet, 0.05);
			// à 100 %, la boucle rend 80 % de ce qu'elle reçoit
			var fbAmt = Lag.kr(feedback, 0.05) * 0.8;
			var out, rec;
			// Le retour est filtré : sous 50 Hz, les grains s'additionnent
			// toujours en phase et la boucle aurait un gain supérieur à 1.
			LocalOut.ar(HPF.ar(HPF.ar(grains, 50), 50));
			// Le retour passe par un limiteur à 0,3. Un feedback normal (gain
			// de boucle sous 1) ne l'atteint pas ; il ne retient que les cas où
			// la boucle résonne, par exemple à 100 % avec la hauteur décalée.
			// L'entrée, elle, est enregistrée telle quelle.
			rec = [bufL, bufR].collect { |b, i|
				var sig = in[i] + Limiter.ar(fb[i] * fbAmt, 0.3, 0.005);
				RecordBuf.ar(sig, b, run: run, loop: 1);
				sig;
			};
			out = (in * (1 - w)) + (grains * w);
			// Pour la visualisation : la tête d'écriture, et le niveau de ce
			// qui s'écrit sous elle. 32 messages par seconde, soit une colonne
			// d'écran par message pour un buffer de 4 s affiché sur 128 px.
			SendReply.kr(Impulse.kr(32), '/sculpt/mos',
				[A2K.kr(wphase) / frames, A2K.kr(Amplitude.ar(rec.sum * 0.5, 0.001, 0.02))]);
			ReplaceOut.ar(bus, (in * (1 - mix)) + (out * mix));
		}).add;

		// Sortie : copie le bus de la chaîne vers la sortie du norns.
		// sortie : un limiteur retient ce qui dépasserait la pleine échelle
		// (sample fort, level au-dessus de 100 %, effet ajouté au direct).
		// Sous le seuil il ne touche à rien. Il anticipe de 5 ms : c'est le
		// retard qu'il ajoute à toute la chaîne.
		SynthDef(\sculpt_out, { |in, out|
			Out.ar(out, Limiter.ar(In.ar(in, 2), 0.99, 0.005));
		}).add;
	}
}
