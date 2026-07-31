using System;
using System.Collections;
using System.Runtime.CompilerServices;
using System.Runtime.ConstrainedExecution;
using System.Security;
using System.Threading;

namespace <CrtImplementationDetails>
{
	// Token: 0x02000074 RID: 116
	internal class ModuleUninitializer : Stack
	{
		// Token: 0x06000159 RID: 345 RVA: 0x00007028 File Offset: 0x00006428
		[SecuritySafeCritical]
		internal void AddHandler(EventHandler handler)
		{
			bool flag = false;
			RuntimeHelpers.PrepareConstrainedRegions();
			try
			{
				RuntimeHelpers.PrepareConstrainedRegions();
				Monitor.Enter(ModuleUninitializer.@lock, ref flag);
				RuntimeHelpers.PrepareDelegate(handler);
				this.Push(handler);
			}
			finally
			{
				if (flag)
				{
					Monitor.Exit(ModuleUninitializer.@lock);
				}
			}
		}

		// Token: 0x0600015B RID: 347 RVA: 0x00007620 File Offset: 0x00006A20
		[SecuritySafeCritical]
		private ModuleUninitializer()
		{
			EventHandler eventHandler = new EventHandler(this.SingletonDomainUnload);
			AppDomain.CurrentDomain.DomainUnload += eventHandler;
			AppDomain.CurrentDomain.ProcessExit += eventHandler;
		}

		// Token: 0x0600015C RID: 348 RVA: 0x00007088 File Offset: 0x00006488
		[SecurityCritical]
		[PrePrepareMethod]
		private void SingletonDomainUnload(object source, EventArgs arguments)
		{
			bool flag = false;
			RuntimeHelpers.PrepareConstrainedRegions();
			try
			{
				RuntimeHelpers.PrepareConstrainedRegions();
				Monitor.Enter(ModuleUninitializer.@lock, ref flag);
				using (IEnumerator enumerator = this.GetEnumerator())
				{
					while (enumerator.MoveNext())
					{
						((EventHandler)enumerator.Current)(source, arguments);
					}
				}
			}
			finally
			{
				if (flag)
				{
					Monitor.Exit(ModuleUninitializer.@lock);
				}
			}
		}

		// Token: 0x04000094 RID: 148
		private static object @lock = new object();

		// Token: 0x04000095 RID: 149
		internal static ModuleUninitializer _ModuleUninitializer = new ModuleUninitializer();
	}
}
