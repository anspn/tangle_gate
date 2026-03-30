import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from 'recharts';
import { format, parseISO } from 'date-fns';

interface CredentialDataPoint {
  date: string;
  issued: number;
  revoked: number;
}

export function CredentialsChart({ data }: { data: CredentialDataPoint[] }) {
  if (data.length === 0) {
    return (
      <div className="flex items-center justify-center h-[280px]">
        <p className="text-sm italic text-tg-text-muted">No credential data available yet.</p>
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={280}>
      <BarChart data={data} margin={{ top: 5, right: 10, left: -10, bottom: 0 }}>
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
          cursor={{ fill: 'hsl(0, 0%, 100%)', fillOpacity: 0.06 }}
          labelFormatter={(v) => format(parseISO(v as string), 'PPP')}
        />
        <Legend
          iconType="rect"
          iconSize={10}
          wrapperStyle={{ fontSize: '12px', paddingTop: '8px' }}
        />
        <Bar
          dataKey="issued"
          name="Issued"
          fill="hsl(160, 95%, 41%)"
          radius={[2, 2, 0, 0]}
        />
        <Bar
          dataKey="revoked"
          name="Revoked"
          fill="hsl(0, 84%, 60%)"
          radius={[2, 2, 0, 0]}
        />
      </BarChart>
    </ResponsiveContainer>
  );
}
