"use client";

import { Activity, CircleDollarSign, RadioTower, ShieldCheck, Wallet } from "lucide-react";
import { useMemo, useState } from "react";

const networks = [
  { name: "Unichain Sepolia", chainId: 1301, manager: "0x00b0...62ac", router: "0xf705...be5d" },
  { name: "Base Sepolia", chainId: 84532, manager: "0x05E7...3408", router: "0x492e...4104" },
  { name: "Reactive Lasna", chainId: 5318007, manager: "System 0x...fffFfF", router: "RSC" }
];

const proof = [
  "RSC deploy",
  "Subscription active",
  "Origin PriceDeviation",
  "RVM queued callback",
  "Destination InsurancePaid"
];

export default function Home() {
  const [positionValue, setPositionValue] = useState(10000);
  const [threshold, setThreshold] = useState(5);
  const [priceMove, setPriceMove] = useState(2);
  const [reserve, setReserve] = useState(5050);

  const il = useMemo(() => {
    const k = priceMove;
    return Math.max(0, 1 - (2 * Math.sqrt(k)) / (1 + k));
  }, [priceMove]);

  const premium = positionValue * 0.005;
  const excess = Math.max(0, il * 100 - threshold);
  const rawPayout = positionValue * (excess / 100);
  const maxCoverage = premium * 20;
  const payout = Math.min(rawPayout, maxCoverage, reserve);
  const reserveRatio = reserve / positionValue;
  const state = reserveRatio < 0.1 ? "DEPLETED" : reserveRatio < 0.3 ? "STRESSED" : "HEALTHY";

  return (
    <main>
      <header className="topbar">
        <div>
          <h1>ReactiveShield</h1>
          <p>The pool insures itself. Reactive settles the claim.</p>
        </div>
        <button className="iconButton" aria-label="Connect wallet" title="Connect wallet">
          <Wallet size={20} />
        </button>
      </header>

      <section className="grid">
        <div className="panel primary">
          <div className="panelHeader">
            <ShieldCheck size={20} />
            <h2>Coverage</h2>
          </div>
          <div className="controls">
            <label>
              Position value
              <input value={positionValue} min={1000} step={500} type="number" onChange={(e) => setPositionValue(Number(e.target.value))} />
            </label>
            <label>
              Deductible
              <input value={threshold} min={2} max={20} step={1} type="range" onChange={(e) => setThreshold(Number(e.target.value))} />
              <span>{threshold}%</span>
            </label>
            <label>
              Price move
              <input value={priceMove} min={0.25} max={4} step={0.25} type="range" onChange={(e) => setPriceMove(Number(e.target.value))} />
              <span>{priceMove.toFixed(2)}x</span>
            </label>
            <label>
              Reserve
              <input value={reserve} min={0} step={250} type="number" onChange={(e) => setReserve(Number(e.target.value))} />
            </label>
          </div>
        </div>

        <div className="panel">
          <div className="panelHeader">
            <CircleDollarSign size={20} />
            <h2>Quote</h2>
          </div>
          <dl className="metrics">
            <div><dt>Premium</dt><dd>${premium.toLocaleString()}</dd></div>
            <div><dt>IL</dt><dd>{(il * 100).toFixed(2)}%</dd></div>
            <div><dt>Excess</dt><dd>{excess.toFixed(2)}%</dd></div>
            <div><dt>Payout</dt><dd>${Math.round(payout).toLocaleString()}</dd></div>
          </dl>
        </div>

        <div className={`panel state ${state.toLowerCase()}`}>
          <div className="panelHeader">
            <Activity size={20} />
            <h2>Reserve</h2>
          </div>
          <strong>{state}</strong>
          <p>${reserve.toLocaleString()} available</p>
          <div className="bar"><span style={{ width: `${Math.min(100, reserveRatio * 100)}%` }} /></div>
        </div>

        <div className="panel">
          <div className="panelHeader">
            <RadioTower size={20} />
            <h2>Reactive Proof</h2>
          </div>
          <ol className="proof">
            {proof.map((item, index) => <li key={item}><span>{index + 1}</span>{item}</li>)}
          </ol>
        </div>
      </section>

      <section className="networkBand">
        {networks.map((network) => (
          <article key={network.chainId}>
            <h3>{network.name}</h3>
            <p>Chain {network.chainId}</p>
            <code>{network.manager}</code>
            <code>{network.router}</code>
          </article>
        ))}
      </section>
    </main>
  );
}

