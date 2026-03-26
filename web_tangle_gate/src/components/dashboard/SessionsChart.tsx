import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from 'recharts';
import { format, parseISO } from 'date-fns';

interface SessionDataPoint {
  date: string;
  total: number;
  notarized: number;
  failed: number;
  active: number;
}

export function SessionsChart({ data }: { data: SessionDataPoint[] }) {
  if (data.length === 0) {
    return (
      <div className="flex items-center justify-center h-[280px]">
        <p className="text-sm italic text-tg-text-muted">No session data available yet.</p>
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={280}>
      <AreaChart data={data} margin={{ top: 5, right: 10, left: -10, bottom: 0 }}>
        <defs>
          <linearGradient id="gradNotarized" x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%" stopColor="hsl(160, 95%, 41%)" stopOpacity={0.3} />
            <stop offset="95%" stopColor="hsl(160, 95%, 41%)" stopOpacity={0} />
          </linearGradient>
          <linearGradient id="gradFailed" x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%" stopColor="hsl(0, 84%, 60%)" stopOpacity={0.3} />
            <stop offset="95%" stopColor="hsl(0, 84%, 60%)" stopOpacity={0} />
          </linearGradient>
          <linearGradient id="gradActive" x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%" stopColor="hsl(207, 100%, 41%)" stopOpacity={0.3} />
            <stop offset="95%" stopColor="hsl(207, 100%, 41%)" stopOpacity={0} />
          </linearGradient>
        </defs>
        <CartesianGrid strokeDasharray="3 3" stroke="hsl(0, 0%, 20%)" />
        <XAxis
          dataKey="date"
          tickFormatter={(v) => format(parseISO(v), 'MMM d')}
          tick={{ fontSize: 11, fill: 'hsl(0, 0%, 55%)' }}
          axisLine={{ stroke: 'hsl(0, 0%, 25%)' }}
          tickLine={false}
        />
        <YAxis
          allowDecimals={false}
          tick={{ fontSize: 11, fill: 'hsl(0, 0%, 55%)' }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip
          contentStyle={{
            backgroundColor: 'hsl(220, 20%, 14%)',
            border: '1px solid hsl(0, 0%, 20%)',
            borderRadius: '8px',
            fontSize: '12px',
          }}
          labelFormatter={(v) => format(parseISO(v as string), 'PPP')}
        />
        <Legend
          iconType="circle"
          iconSize={8}
          wrapperStyle={{ fontSize: '12px', paddingTop: '8px' }}
        />
        <Area
          type="monotone"
          dataKey="notarized"
          name="Notarized"
          stroke="hsl(160, 95%, 41%)"
          fill="url(#gradNotarized)"
          strokeWidth={2}
        />
        <Area
          type="monotone"
          dataKey="failed"
          name="Failed"
          stroke="hsl(0, 84%, 60%)"
          fill="url(#gradFailed)"
          strokeWidth={2}
        />
        <Area
          type="monotone"
          dataKey="active"
          name="Active"
          stroke="hsl(207, 100%, 41%)"
          fill="url(#gradActive)"
          strokeWidth={2}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
