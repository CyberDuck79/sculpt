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

		// Sortie : pour l'instant la source telle quelle. La chaîne d'effets
		// s'insérera entre la source et ce synth.
		SynthDef(\sculpt_out, { |in, out|
			Out.ar(out, In.ar(in, 2));
		}).add;
	}
}
