using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.ConstrainedExecution;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Permissions;
using System.Threading;
using <CppImplementationDetails>;
using <CrtImplementationDetails>;
using msclr;
using msclr.interop.details;
using phmap;
using phmap.priv;
using phmap.priv.internal_layout;
using std;
using std.?append@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@$$FQAEAAV12@ID@Z.__l2;
using std.?assign@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@$$FQAEAAV12@QBDI@Z.__l2;
using std.chrono;

// Token: 0x02000001 RID: 1
internal class <Module>
{
	// Token: 0x06000001 RID: 1 RVA: 0x00001794 File Offset: 0x00000B94
	internal unsafe static time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* std.chrono.steady_clock.now(time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* A_0)
	{
		long num = <Module>._Query_perf_frequency();
		long num2 = <Module>._Query_perf_counter();
		duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020> = num2 % num * 1000000000L / num + num2 / num * 1000000000L;
		cpblk(A_0, ref duration<__int64,std::ratio<1,1000000000>_u0020>, 8);
		return A_0;
	}

	// Token: 0x06000002 RID: 2 RVA: 0x000017D0 File Offset: 0x00000BD0
	internal unsafe static void std.thread.{dtor}(thread* A_0)
	{
		if (((*(A_0 + 4) != 0) ? 1 : 0) != 0)
		{
			<Module>.terminate();
		}
	}

	// Token: 0x06000003 RID: 3 RVA: 0x00001228 File Offset: 0x00000628
	internal unsafe static void std.thread.detach(thread* A_0)
	{
		if (((*(A_0 + 4) != 0) ? 1 : 0) == 0)
		{
			<Module>.std._Throw_Cpp_error(1);
		}
		int num = <Module>._Thrd_detach(*A_0);
		if (num != 0)
		{
			<Module>.std._Throw_C_error(num);
		}
		_Thrd_t thrd_t;
		initblk(ref thrd_t, 0, 8);
		cpblk(A_0, ref thrd_t, 8);
	}

	// Token: 0x06000004 RID: 4 RVA: 0x0000126C File Offset: 0x0000066C
	internal unsafe static void CDataStore.{dtor}(CDataStore* A_0)
	{
		*A_0 = ref <Module>.??_7CDataStore@@6B@;
		delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;
		calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), A_0, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
	}

	// Token: 0x06000005 RID: 5 RVA: 0x00001CD0 File Offset: 0x000010D0
	internal unsafe static CDataStore* CDataStore.PutString(CDataStore* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* pString)
	{
		delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*) = <Module>.?fpPutString@CDataStore@@0P6EAAV1@PAV1@PBD@ZA;
		sbyte* ptr = pString;
		if (((16 <= *(pString + 20)) ? 1 : 0) != 0)
		{
			ptr = *pString;
		}
		return calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.SByte modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte) modopt(System.Runtime.CompilerServices.IsConst)*), A_0, ptr, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*));
	}

	// Token: 0x06000006 RID: 6 RVA: 0x00002AA0 File Offset: 0x00001EA0
	internal unsafe static ProcessDescription* ProcessDescription.{ctor}(ProcessDescription* A_0, Process process)
	{
		<Module>.std._String_val<std::_Simple_types<char>\u0020>.{ctor}(A_0);
		try
		{
			*(A_0 + 16) = 0;
			*(A_0 + 20) = 15;
			*A_0 = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
		try
		{
			ProcessDescription* ptr = A_0 + 24;
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = ptr;
			<Module>.std._String_val<std::_Simple_types<char>\u0020>.{ctor}(ptr2);
			try
			{
				*(ptr2 + 16) = 0;
				*(ptr2 + 20) = 15;
				*ptr2 = 0;
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), ptr2);
				throw;
			}
			try
			{
				ProcessDescription* ptr3 = A_0 + 48;
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr4 = ptr3;
				<Module>.std._String_val<std::_Simple_types<char>\u0020>.{ctor}(ptr4);
				try
				{
					*(ptr4 + 16) = 0;
					*(ptr4 + 20) = 15;
					*ptr4 = 0;
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), ptr4);
					throw;
				}
				try
				{
					ProcessDescription* ptr5 = A_0 + 72;
					*ptr5 = 0;
					try
					{
						string processName = process.ProcessName;
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>;
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr6 = <Module>.msclr.interop.marshal_as<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>,class\u0020System::String\u0020^>(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>, ref processName);
						try
						{
							if (A_0 != ptr6)
							{
								_Equal_allocators equal_allocators;
								initblk(ref equal_allocators, 0, 1);
								_Equal_allocators equal_allocators2;
								cpblk(ref equal_allocators2, ref equal_allocators, 1);
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(A_0);
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(A_0, ptr6);
							}
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
							throw;
						}
						try
						{
							<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
							throw;
						}
						string mainWindowTitle = process.MainWindowTitle;
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2;
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr7 = <Module>.msclr.interop.marshal_as<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>,class\u0020System::String\u0020^>(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2, ref mainWindowTitle);
						try
						{
							basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr8 = ptr;
							if (ptr8 != ptr7)
							{
								_Equal_allocators equal_allocators3;
								initblk(ref equal_allocators3, 0, 1);
								_Equal_allocators equal_allocators4;
								cpblk(ref equal_allocators4, ref equal_allocators3, 1);
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr8);
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(ptr8, ptr7);
							}
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2));
							throw;
						}
						try
						{
							<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2);
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2));
							throw;
						}
						*ptr5 = 1;
						try
						{
							string fileName = process.MainModule.FileName;
							basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3;
							basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr9 = <Module>.msclr.interop.marshal_as<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>,class\u0020System::String\u0020^>(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3, ref fileName);
							try
							{
								basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr10 = ptr3;
								if (ptr10 != ptr9)
								{
									_Equal_allocators equal_allocators5;
									initblk(ref equal_allocators5, 0, 1);
									_Equal_allocators equal_allocators6;
									cpblk(ref equal_allocators6, ref equal_allocators5, 1);
									<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr10);
									<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(ptr10, ptr9);
								}
							}
							catch
							{
								<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3));
								throw;
							}
							try
							{
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3);
							}
							catch
							{
								<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3));
								throw;
							}
						}
						catch (Exception ex)
						{
							sbyte* ptr11 = ref <Module>.??_C@_07NBCGADJA@Unknown@;
							while (*ptr11 != 0)
							{
								ptr11++;
							}
							uint num = ptr11 - (ref <Module>.??_C@_07NBCGADJA@Unknown@);
							<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.assign(A_0 + 48, ref <Module>.??_C@_07NBCGADJA@Unknown@, num);
						}
					}
					catch (Exception ex2)
					{
					}
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), A_0 + 48);
					throw;
				}
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), A_0 + 24);
				throw;
			}
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x06000007 RID: 7 RVA: 0x00002E38 File Offset: 0x00002238
	internal unsafe static CDataStore* CDataStoreManagedHelper.PutString(CDataStore* store, string pString)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>;
		<Module>.msclr.interop.marshal_as<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>,class\u0020System::String\u0020^>(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>, ref pString);
		CDataStore* ptr;
		try
		{
			ptr = <Module>.CDataStore.PutString(store, ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
			throw;
		}
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
			throw;
		}
		return ptr;
	}

	// Token: 0x06000008 RID: 8 RVA: 0x00003228 File Offset: 0x00002628
	internal unsafe static void AntiCheatService.DetectHackProcesses(AntiCheatService* A_0, [MarshalAs(UnmanagedType.U1)] bool report, [MarshalAs(UnmanagedType.U1)] bool sleep)
	{
		Process process = null;
		int num = (int)stackalloc byte[<Module>.__CxxQueryExceptionSize()];
		foreach (Process process in Process.GetProcesses())
		{
			exception* ptr2;
			try
			{
				string text = process.ProcessName.ToLower();
				foreach (string text2 in BannedProccessesManaged.GetInstance().GetNormalizedManagedProccesses())
				{
					if (text.Contains(text2))
					{
						shared_ptr<ProcessDescription> shared_ptr<ProcessDescription>;
						initblk(ref shared_ptr<ProcessDescription>, 0, 8);
						<Module>.std.make_shared<class\u0020ProcessDescription,class\u0020System::Diagnostics::Process\u0020^\u0020&>(&shared_ptr<ProcessDescription>, ref process);
						try
						{
							if (report)
							{
								byte b = *(shared_ptr<ProcessDescription> + 72);
								if (b != 0)
								{
									shared_ptr<ProcessDescription> shared_ptr<ProcessDescription>2;
									shared_ptr<ProcessDescription>* ptr = <Module>.std.shared_ptr<ProcessDescription>.{ctor}(ref shared_ptr<ProcessDescription>2, ref shared_ptr<ProcessDescription>);
									<Module>.AntiCheatService.SendProcessAntiCheatAlert(A_0, ptr);
								}
							}
							if (sleep)
							{
								duration<__int64,std::ratio<1,1000>\u0020> duration<__int64,std::ratio<1,1000>_u0020> = 50L;
								time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
								<Module>.std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(<Module>.std._To_absolute_time<__int64,struct\u0020std::ratio<1,1000>\u0020>(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, ref duration<__int64,std::ratio<1,1000>_u0020>));
							}
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std.shared_ptr<ProcessDescription>.{dtor}), (void*)(&shared_ptr<ProcessDescription>));
							throw;
						}
						if (*((ref shared_ptr<ProcessDescription>) + 4) != 0)
						{
							<Module>.std._Ref_count_base._Decref(*((ref shared_ptr<ProcessDescription>) + 4));
						}
					}
				}
			}
			catch (Exception ex)
			{
			}
			catch when (endfilter(<Module>.__CxxExceptionFilter(Marshal.GetExceptionPointers(), (void*)(&<Module>.??_R0?AVexception@std@@@8), 8, (void*)(&ptr2)) != null))
			{
				uint num2 = 0U;
				<Module>.__CxxRegisterExceptionObject(Marshal.GetExceptionPointers(), num);
				try
				{
					try
					{
						goto IL_012F;
					}
					catch when (delegate
					{
						// Failed to create a 'catch-when' expression
						num2 = <Module>.__CxxDetectRethrow(Marshal.GetExceptionPointers());
						endfilter(num2 != 0U);
					})
					{
					}
					if (num2 != 0U)
					{
						throw;
					}
				}
				finally
				{
					<Module>.__CxxUnregisterExceptionObject(num, (int)num2);
				}
			}
			IL_012F:;
		}
	}

	// Token: 0x06000009 RID: 9 RVA: 0x000033EC File Offset: 0x000027EC
	internal unsafe static void AntiCheatService.DetectHackTitles(AntiCheatService* A_0, [MarshalAs(UnmanagedType.U1)] bool report, [MarshalAs(UnmanagedType.U1)] bool sleep)
	{
		Process process = null;
		int num = (int)stackalloc byte[<Module>.__CxxQueryExceptionSize()];
		foreach (Process process in Process.GetProcesses())
		{
			exception* ptr2;
			try
			{
				string text = process.MainWindowTitle.ToLower();
				foreach (string text2 in BannedProccessesManaged.GetInstance().GetNormalizedManagedTitles())
				{
					if (text.Contains(text2))
					{
						shared_ptr<ProcessDescription> shared_ptr<ProcessDescription>;
						initblk(ref shared_ptr<ProcessDescription>, 0, 8);
						<Module>.std.make_shared<class\u0020ProcessDescription,class\u0020System::Diagnostics::Process\u0020^\u0020&>(&shared_ptr<ProcessDescription>, ref process);
						try
						{
							if (report)
							{
								byte b = *(shared_ptr<ProcessDescription> + 72);
								if (b != 0)
								{
									shared_ptr<ProcessDescription> shared_ptr<ProcessDescription>2;
									shared_ptr<ProcessDescription>* ptr = <Module>.std.shared_ptr<ProcessDescription>.{ctor}(ref shared_ptr<ProcessDescription>2, ref shared_ptr<ProcessDescription>);
									<Module>.AntiCheatService.SendProcessAntiCheatAlert(A_0, ptr);
								}
							}
							if (sleep)
							{
								duration<__int64,std::ratio<1,1000>\u0020> duration<__int64,std::ratio<1,1000>_u0020> = 50L;
								time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
								<Module>.std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(<Module>.std._To_absolute_time<__int64,struct\u0020std::ratio<1,1000>\u0020>(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, ref duration<__int64,std::ratio<1,1000>_u0020>));
							}
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std.shared_ptr<ProcessDescription>.{dtor}), (void*)(&shared_ptr<ProcessDescription>));
							throw;
						}
						if (*((ref shared_ptr<ProcessDescription>) + 4) != 0)
						{
							<Module>.std._Ref_count_base._Decref(*((ref shared_ptr<ProcessDescription>) + 4));
						}
					}
				}
			}
			catch (Exception ex)
			{
			}
			catch when (endfilter(<Module>.__CxxExceptionFilter(Marshal.GetExceptionPointers(), (void*)(&<Module>.??_R0?AVexception@std@@@8), 8, (void*)(&ptr2)) != null))
			{
				uint num2 = 0U;
				<Module>.__CxxRegisterExceptionObject(Marshal.GetExceptionPointers(), num);
				try
				{
					try
					{
						goto IL_012F;
					}
					catch when (delegate
					{
						// Failed to create a 'catch-when' expression
						num2 = <Module>.__CxxDetectRethrow(Marshal.GetExceptionPointers());
						endfilter(num2 != 0U);
					})
					{
					}
					if (num2 != 0U)
					{
						throw;
					}
				}
				finally
				{
					<Module>.__CxxUnregisterExceptionObject(num, (int)num2);
				}
			}
			IL_012F:;
		}
	}

	// Token: 0x0600000A RID: 10 RVA: 0x00003088 File Offset: 0x00002488
	internal unsafe static void AntiCheatService.DetectHackModules(AntiCheatService* A_0, [MarshalAs(UnmanagedType.U1)] bool report, [MarshalAs(UnmanagedType.U1)] bool sleep)
	{
		foreach (ProcessModule processModule in Process.GetCurrentProcess().Modules)
		{
			List<string> normalizedManagedModules = BannedProccessesManaged.GetInstance().GetNormalizedManagedModules();
			string text = processModule.ModuleName.ToLower();
			if (normalizedManagedModules.Contains(text) && report)
			{
				<Module>.AntiCheatService.SendModuleAntiCheatAlert(A_0, processModule);
			}
			if (sleep)
			{
				duration<__int64,std::ratio<1,1000>\u0020> duration<__int64,std::ratio<1,1000>_u0020> = 50L;
				time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
				<Module>.std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(<Module>.std._To_absolute_time<__int64,struct\u0020std::ratio<1,1000>\u0020>(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, ref duration<__int64,std::ratio<1,1000>_u0020>));
			}
		}
	}

	// Token: 0x0600000B RID: 11 RVA: 0x00002EB8 File Offset: 0x000022B8
	internal unsafe static void AntiCheatService.DetectDebugger(AntiCheatService* A_0)
	{
		if (<Module>.IsDebuggerPresent() != null)
		{
			CDataStore cdataStore;
			initblk(ref cdataStore, 0, 24);
			cdataStore = ref <Module>.??_7CDataStore@@6B@;
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpInit@CDataStore@@0P6EPAV1@PAV1@@ZA;
			CDataStore* ptr = calli(CDataStore* modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32) = <Module>.?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;
			CDataStore* ptr2 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.Int32), &cdataStore, 1311, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32));
			try
			{
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, "DEBUGGER");
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, "DEBUGGER");
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, Process.GetCurrentProcess().ProcessName);
				delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpFinalize@CDataStore@@0P6EXPAV1@@ZA;
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
				delegate* unmanaged[Thiscall, Thiscall]<void*, CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*) = <Module>.?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA;
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.Void*,CDataStore*), calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*));
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(CDataStore.{dtor}), (void*)(&cdataStore));
				throw;
			}
			cdataStore = ref <Module>.??_7CDataStore@@6B@;
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2 = <Module>.?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;
			calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2);
		}
	}

	// Token: 0x0600000C RID: 12 RVA: 0x000022F0 File Offset: 0x000016F0
	internal unsafe static void AntiCheatService.SendProcessAntiCheatAlert(AntiCheatService* A_0, shared_ptr<ProcessDescription>* processInfo)
	{
		try
		{
			if (calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA) != null)
			{
				CDataStore cdataStore;
				initblk(ref cdataStore, 0, 24);
				cdataStore = ref <Module>.??_7CDataStore@@6B@;
				delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpInit@CDataStore@@0P6EPAV1@PAV1@@ZA;
				CDataStore* ptr = calli(CDataStore* modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
				delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32) = <Module>.?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;
				CDataStore* ptr2 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.Int32), &cdataStore, 1311, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32));
				try
				{
					ProcessDescription* ptr3 = *(int*)processInfo;
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*) = <Module>.?fpPutString@CDataStore@@0P6EAAV1@PAV1@PBD@ZA;
					sbyte* ptr4 = (sbyte*)ptr3;
					if (((16 <= *(int*)(ptr3 + 20 / sizeof(ProcessDescription))) ? 1 : 0) != 0)
					{
						ptr4 = *(int*)ptr3;
					}
					CDataStore* ptr5 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.SByte modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte) modopt(System.Runtime.CompilerServices.IsConst)*), &cdataStore, ptr4, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*));
					basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr6 = *(int*)processInfo + 24;
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*)2 = <Module>.?fpPutString@CDataStore@@0P6EAAV1@PAV1@PBD@ZA;
					sbyte* ptr7 = ptr6;
					if (((16 <= *(ptr6 + 20)) ? 1 : 0) != 0)
					{
						ptr7 = *ptr6;
					}
					CDataStore* ptr8 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.SByte modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte) modopt(System.Runtime.CompilerServices.IsConst)*), &cdataStore, ptr7, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*)2);
					basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr9 = *(int*)processInfo + 48;
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*)3 = <Module>.?fpPutString@CDataStore@@0P6EAAV1@PAV1@PBD@ZA;
					sbyte* ptr10 = ptr9;
					if (((16 <= *(ptr9 + 20)) ? 1 : 0) != 0)
					{
						ptr10 = *ptr9;
					}
					CDataStore* ptr11 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.SByte modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte) modopt(System.Runtime.CompilerServices.IsConst)*), &cdataStore, ptr10, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)_u0020modopt(System.Runtime.CompilerServices.IsConst)*)3);
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpFinalize@CDataStore@@0P6EXPAV1@@ZA;
					calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
					delegate* unmanaged[Thiscall, Thiscall]<void*, CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*) = <Module>.?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA;
					calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.Void*,CDataStore*), calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*));
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(CDataStore.{dtor}), (void*)(&cdataStore));
					throw;
				}
				cdataStore = ref <Module>.??_7CDataStore@@6B@;
				delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2 = <Module>.?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2);
			}
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.shared_ptr<ProcessDescription>.{dtor}), (void*)processInfo);
			throw;
		}
		uint num = (uint)(*(int*)(processInfo + 4 / sizeof(shared_ptr<ProcessDescription>)));
		if (num != 0U)
		{
			<Module>.std._Ref_count_base._Decref(num);
		}
	}

	// Token: 0x0600000D RID: 13 RVA: 0x00002F9C File Offset: 0x0000239C
	internal unsafe static void AntiCheatService.SendModuleAntiCheatAlert(AntiCheatService* A_0, ProcessModule moduleInfo)
	{
		if (calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA) != null)
		{
			CDataStore cdataStore;
			initblk(ref cdataStore, 0, 24);
			cdataStore = ref <Module>.??_7CDataStore@@6B@;
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpInit@CDataStore@@0P6EPAV1@PAV1@@ZA;
			CDataStore* ptr = calli(CDataStore* modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32) = <Module>.?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;
			CDataStore* ptr2 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.Int32), &cdataStore, 1311, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32));
			try
			{
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, moduleInfo.ModuleName);
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, Process.GetCurrentProcess().MainWindowTitle);
				<Module>.CDataStoreManagedHelper.PutString(ref cdataStore, moduleInfo.FileName);
				delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpFinalize@CDataStore@@0P6EXPAV1@@ZA;
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
				delegate* unmanaged[Thiscall, Thiscall]<void*, CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*) = <Module>.?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA;
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.Void*,CDataStore*), calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*));
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(CDataStore.{dtor}), (void*)(&cdataStore));
				throw;
			}
			cdataStore = ref <Module>.??_7CDataStore@@6B@;
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2 = <Module>.?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;
			calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2);
		}
	}

	// Token: 0x0600000E RID: 14 RVA: 0x000035B0 File Offset: 0x000029B0
	internal unsafe static void AntiCheatThreadLoop()
	{
		<Module>.FixInvalidPtrCheck();
		<Module>.SetMessageHandlers();
		for (;;)
		{
			AntiCheatService antiCheatService;
			<Module>.AntiCheatService.DetectHackProcesses(ref antiCheatService, true, true);
			duration<__int64,std::ratio<1,1>\u0020> duration<__int64,std::ratio<1,1>_u0020> = 60L;
			time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
			<Module>.std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(<Module>.std._To_absolute_time<__int64,struct\u0020std::ratio<1,1>\u0020>(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, ref duration<__int64,std::ratio<1,1>_u0020>));
			<Module>.AntiCheatService.DetectHackModules(ref antiCheatService, true, true);
			duration<__int64,std::ratio<1,1>\u0020> duration<__int64,std::ratio<1,1>_u0020>2 = 60L;
			time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>2;
			<Module>.std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(<Module>.std._To_absolute_time<__int64,struct\u0020std::ratio<1,1>\u0020>(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>2, ref duration<__int64,std::ratio<1,1>_u0020>2));
			<Module>.AntiCheatService.DetectHackTitles(ref antiCheatService, true, true);
			<Module>.AntiCheatService.DetectDebugger(ref antiCheatService);
		}
	}

	// Token: 0x0600000F RID: 15 RVA: 0x00001E38 File Offset: 0x00001238
	internal unsafe static void std.shared_ptr<ProcessDescription>.{dtor}(shared_ptr<ProcessDescription>* A_0)
	{
		uint num = (uint)(*(A_0 + 4));
		if (num != 0U)
		{
			<Module>.std._Ref_count_base._Decref(num);
		}
	}

	// Token: 0x06000010 RID: 16 RVA: 0x00001E54 File Offset: 0x00001254
	internal unsafe static shared_ptr<ProcessDescription>* std.shared_ptr<ProcessDescription>.{ctor}(shared_ptr<ProcessDescription>* A_0, shared_ptr<ProcessDescription>* _Other)
	{
		<Module>.std._Ptr_base<ProcessDescription>.{ctor}(A_0);
		uint num = (uint)(*(_Other + 4));
		if (num != 0U)
		{
			Interlocked.Increment(num + 4U);
		}
		*A_0 = *_Other;
		*(A_0 + 4) = *(_Other + 4);
		return A_0;
	}

	// Token: 0x06000011 RID: 17 RVA: 0x00001E88 File Offset: 0x00001288
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0)
	{
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = num;
			if (ptr2 != ptr)
			{
				do
				{
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.__delDtor(ptr2, 0U);
					ptr2 += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr2 != ptr);
			}
			num = (uint)(*A_0);
			uint num2 = (uint)((*(A_0 + 8) - (int)num) / 24 * 24);
			void* ptr3 = num;
			if (num2 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr3, ref num2);
			}
			<Module>.delete(ptr3, num2);
			*A_0 = 0;
			*(A_0 + 4) = 0;
			*(A_0 + 8) = 0;
		}
	}

	// Token: 0x06000012 RID: 18 RVA: 0x00001EF0 File Offset: 0x000012F0
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Buy_raw(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint _Newcapacity)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = <Module>.std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.allocate(A_0, _Newcapacity);
		*A_0 = ptr;
		*(A_0 + 4) = ptr;
		*(A_0 + 8) = _Newcapacity * 24 + ptr;
	}

	// Token: 0x06000013 RID: 19 RVA: 0x00001F18 File Offset: 0x00001318
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Construct_lv_contents(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Right)
	{
		uint num = *(_Right + 16);
		sbyte* ptr = _Right;
		if (((16 <= *(_Right + 20)) ? 1 : 0) != 0)
		{
			ptr = *_Right;
		}
		if (num < 16)
		{
			cpblk(A_0, ptr, 16);
			*(A_0 + 16) = num;
			*(A_0 + 20) = 15;
		}
		else
		{
			uint num2 = <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(A_0);
			uint num3 = num | 15;
			uint num4 = num3;
			uint num5 = *(ref num2 < num3 ? ref num2 : ref num4);
			uint num6 = num5 + 1;
			void* ptr2;
			if (num6 >= 4096)
			{
				ptr2 = <Module>.std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(num6);
			}
			else if (num6 != null)
			{
				ptr2 = <Module>.@new(num6);
			}
			else
			{
				ptr2 = null;
			}
			*A_0 = ptr2;
			cpblk(ptr2, ptr, num + 1);
			*(A_0 + 16) = num;
			*(A_0 + 20) = num5;
		}
	}

	// Token: 0x06000014 RID: 20 RVA: 0x000019E0 File Offset: 0x00000DE0
	internal unsafe static allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>* std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Getal(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0)
	{
		return A_0;
	}

	// Token: 0x06000015 RID: 21 RVA: 0x00001BA4 File Offset: 0x00000FA4
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Destroy(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _First, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Last)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = _First;
		if (_First != _Last)
		{
			do
			{
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.__delDtor(ptr, 0U);
				ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (ptr != _Last);
		}
	}

	// Token: 0x06000016 RID: 22 RVA: 0x00001BC8 File Offset: 0x00000FC8
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.allocate(allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>* A_0, uint _Count)
	{
		if (_Count > 178956970)
		{
			<Module>.std._Throw_bad_array_new_length();
		}
		uint num = _Count * 24;
		void* ptr;
		if (num >= 4096U)
		{
			ptr = <Module>.std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(num);
		}
		else if (num != 0U)
		{
			ptr = <Module>.@new(num);
		}
		else
		{
			ptr = null;
		}
		return ptr;
	}

	// Token: 0x06000017 RID: 23 RVA: 0x000019F0 File Offset: 0x00000DF0
	internal unsafe static void std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.deallocate(allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Ptr, uint _Count)
	{
		uint num = _Count * 24;
		void* ptr = _Ptr;
		if (num >= 4096U)
		{
			<Module>.std._Adjust_manually_vector_aligned(ref ptr, ref num);
		}
		<Module>.delete(ptr, num);
	}

	// Token: 0x06000018 RID: 24 RVA: 0x0000318C File Offset: 0x0000258C
	internal unsafe static shared_ptr<ProcessDescription>* std.make_shared<class\u0020ProcessDescription,class\u0020System::Diagnostics::Process\u0020^\u0020&>(shared_ptr<ProcessDescription>* A_0, Process* <_Args_0>)
	{
		try
		{
			uint num = 0U;
			_Ref_count_obj2<ProcessDescription>* ptr = <Module>.@new(88U);
			_Ref_count_obj2<ProcessDescription>* ptr2;
			try
			{
				if (ptr != null)
				{
					ptr2 = <Module>.std._Ref_count_obj2<ProcessDescription>.{ctor}<class\u0020System::Diagnostics::Process\u0020^\u0020&>(ptr, <_Args_0>);
				}
				else
				{
					ptr2 = null;
				}
			}
			catch
			{
				<Module>.delete((void*)ptr, 88U);
				throw;
			}
			initblk(A_0, 0, 8);
			<Module>.std.shared_ptr<ProcessDescription>.{ctor}(A_0);
			num = 1U;
			*(int*)A_0 = ptr2 + 12 / sizeof(_Ref_count_obj2<ProcessDescription>);
			*(int*)(A_0 + 4 / sizeof(shared_ptr<ProcessDescription>)) = ptr2;
		}
		catch
		{
			uint num;
			if ((num & 1U) != 0U)
			{
				num &= 4294967294U;
				<Module>.___CxxCallUnwindDtor(ldftn(std.shared_ptr<ProcessDescription>.{dtor}), (void*)A_0);
			}
			throw;
		}
		return A_0;
	}

	// Token: 0x06000019 RID: 25 RVA: 0x00002490 File Offset: 0x00001890
	internal unsafe static time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* std._To_absolute_time<__int64,struct\u0020std::ratio<1,1000>\u0020>(time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* A_0, duration<__int64,std::ratio<1,1000>\u0020>* _Rel_time)
	{
		time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
		<Module>.std.chrono.steady_clock.now((time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>*)(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>));
		cpblk(A_0, ref time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, 8);
		duration<__int64,std::ratio<1,1000>\u0020> duration<__int64,std::ratio<1,1000>_u0020>;
		cpblk(ref duration<__int64,std::ratio<1,1000>_u0020>, _Rel_time, 8);
		if (((0L >= duration<__int64,std::ratio<1,1000>_u0020>) ? 0 : 1) != 0)
		{
			time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> maxValue = long.MaxValue;
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>;
			duration<__int64,std::ratio<1,1000000000>\u0020>* ptr = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>, _Rel_time);
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>2 = long.MaxValue - *ptr;
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>3;
			cpblk(ref duration<__int64,std::ratio<1,1000000000>_u0020>3, A_0, 8);
			if (((duration<__int64,std::ratio<1,1000000000>_u0020>3 >= duration<__int64,std::ratio<1,1000000000>_u0020>2) ? 0 : 1) != 0)
			{
				duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>4;
				duration<__int64,std::ratio<1,1000000000>\u0020>* ptr2 = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>4, _Rel_time);
				*(long*)A_0 = *(long*)A_0 + *ptr2;
			}
			else
			{
				cpblk(A_0, ref maxValue, 8);
			}
		}
		return A_0;
	}

	// Token: 0x0600001A RID: 26 RVA: 0x00001FB8 File Offset: 0x000013B8
	internal unsafe static time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* std._To_absolute_time<__int64,struct\u0020std::ratio<1,1>\u0020>(time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* A_0, duration<__int64,std::ratio<1,1>\u0020>* _Rel_time)
	{
		time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
		<Module>.std.chrono.steady_clock.now((time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>*)(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>));
		cpblk(A_0, ref time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>, 8);
		duration<__int64,std::ratio<1,1>\u0020> duration<__int64,std::ratio<1,1>_u0020>;
		cpblk(ref duration<__int64,std::ratio<1,1>_u0020>, _Rel_time, 8);
		if (((0L >= duration<__int64,std::ratio<1,1>_u0020>) ? 0 : 1) != 0)
		{
			time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> maxValue = long.MaxValue;
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>;
			duration<__int64,std::ratio<1,1000000000>\u0020>* ptr = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>, _Rel_time);
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>2 = long.MaxValue - *ptr;
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>3;
			cpblk(ref duration<__int64,std::ratio<1,1000000000>_u0020>3, A_0, 8);
			if (((duration<__int64,std::ratio<1,1000000000>_u0020>3 >= duration<__int64,std::ratio<1,1000000000>_u0020>2) ? 0 : 1) != 0)
			{
				duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>4;
				duration<__int64,std::ratio<1,1000000000>\u0020>* ptr2 = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>4, _Rel_time);
				*(long*)A_0 = *(long*)A_0 + *ptr2;
			}
			else
			{
				cpblk(A_0, ref maxValue, 8);
			}
		}
		return A_0;
	}

	// Token: 0x0600001B RID: 27 RVA: 0x000027C0 File Offset: 0x00001BC0
	internal unsafe static thread* std.thread.{ctor}<void\u0020(__cdecl&)(void),0>(thread* A_0, delegate* unmanaged[Cdecl, Cdecl]<void> _Fx)
	{
		<Module>.std.thread._Start<void\u0020(__cdecl&)(void)>(A_0, _Fx);
		return A_0;
	}

	// Token: 0x0600001C RID: 28 RVA: 0x0000382C File Offset: 0x00002C2C
	internal unsafe static void std._Ref_count_obj2<ProcessDescription>._Delete_this(_Ref_count_obj2<ProcessDescription>* A_0)
	{
		if (A_0 != null)
		{
			int num = *(*A_0 + 8);
			void* ptr = calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.IntPtr,System.UInt32), A_0, 1U, (IntPtr)num);
		}
	}

	// Token: 0x0600001D RID: 29 RVA: 0x0000380C File Offset: 0x00002C0C
	internal unsafe static void std._Ref_count_obj2<ProcessDescription>._Destroy(_Ref_count_obj2<ProcessDescription>* A_0)
	{
		<Module>.ProcessDescription.__delDtor(A_0 + 12, 0U);
	}

	// Token: 0x0600001E RID: 30 RVA: 0x000038C0 File Offset: 0x00002CC0
	internal unsafe static void std._Ref_count_obj2<ProcessDescription>.{dtor}(_Ref_count_obj2<ProcessDescription>* A_0)
	{
		*A_0 = ref <Module>.??_7?$_Ref_count_obj2@VProcessDescription@@@std@@6B@;
	}

	// Token: 0x0600001F RID: 31 RVA: 0x00003130 File Offset: 0x00002530
	internal unsafe static _Ref_count_obj2<ProcessDescription>* std._Ref_count_obj2<ProcessDescription>.{ctor}<class\u0020System::Diagnostics::Process\u0020^\u0020&>(_Ref_count_obj2<ProcessDescription>* A_0, Process* <_Args_0>)
	{
		initblk(A_0, 0, 12);
		*(A_0 + 4) = 1;
		*(A_0 + 8) = 1;
		try
		{
			*A_0 = ref <Module>.??_7?$_Ref_count_obj2@VProcessDescription@@@std@@6B@;
			<Module>.ProcessDescription.{ctor}(A_0 + 12, *<_Args_0>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Ref_count_base.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x06000020 RID: 32 RVA: 0x000027D8 File Offset: 0x00001BD8
	internal unsafe static void std.this_thread.sleep_until<struct\u0020std::chrono::steady_clock,class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>\u0020>(time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>* _Abs_time)
	{
		for (;;)
		{
			time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020> time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
			<Module>.std.chrono.steady_clock.now((time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>\u0020>\u0020>*)(&time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>));
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>;
			cpblk(ref duration<__int64,std::ratio<1,1000000000>_u0020>, _Abs_time, 8);
			if (((((time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020> >= duration<__int64,std::ratio<1,1000000000>_u0020>) ? 0 : 1) == 0) ? 1 : 0) != 0)
			{
				break;
			}
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>2;
			cpblk(ref duration<__int64,std::ratio<1,1000000000>_u0020>2, _Abs_time, 8);
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>3 = duration<__int64,std::ratio<1,1000000000>_u0020>2 - time_point<std::chrono::steady_clock,std::chrono::duration<__int64,std::ratio<1,1000000000>_u0020>_u0020>;
			xtime xtime;
			<Module>.std._To_xtime_10_day_clamped<__int64,struct\u0020std::ratio<1,1000000000>\u0020>(ref xtime, ref duration<__int64,std::ratio<1,1000000000>_u0020>3);
			<Module>._Thrd_sleep((xtime*)(&xtime));
		}
	}

	// Token: 0x06000021 RID: 33 RVA: 0x00002514 File Offset: 0x00001914
	internal unsafe static void std.thread._Start<void\u0020(__cdecl&)(void)>(thread* A_0, delegate* unmanaged[Cdecl, Cdecl]<void> _Fx)
	{
		unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020> unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>;
		<Module>.std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.__autoclassinit2(ref unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>, 4U);
		<Module>.std.make_unique<class\u0020std::tuple<void\u0020(__cdecl*)(void)>,void\u0020(__cdecl&)(void),0>(&unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>, _Fx);
		try
		{
			delegate* unmanaged[Stdcall, Stdcall]<void*, uint> _unep@??$_Invoke@V?$tuple@P6AXXZ@std@@$0A@@thread@std@@$$FCGIPAX@Z = <Module>.__unep@??$_Invoke@V?$tuple@P6AXXZ@std@@$0A@@thread@std@@$$FCGIPAX@Z;
			thread* ptr = A_0 + 4;
			uint num = <Module>._beginthreadex(null, 0U, _unep@??$_Invoke@V?$tuple@P6AXXZ@std@@$0A@@thread@std@@$$FCGIPAX@Z, unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>, 0U, ptr);
			*A_0 = (int)num;
			if (num == 0U)
			{
				goto IL_0051;
			}
			unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020> = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}), (void*)(&unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>));
			throw;
		}
		<Module>.std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}(ref unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>);
		return;
		IL_0051:
		try
		{
			thread* ptr;
			*ptr = 0;
			<Module>.std._Throw_Cpp_error(6);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}), (void*)(&unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>));
			throw;
		}
	}

	// Token: 0x06000022 RID: 34 RVA: 0x00002968 File Offset: 0x00001D68
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std._Uninitialized_copy<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _First, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Last, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Dest, allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>* _Al)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = _First;
		_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>;
		<Module>.std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.__autoclassinit2(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, 12U);
		uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020> = _Dest;
		*((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4) = _Dest;
		*((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 8) = _Al;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2;
		try
		{
			if (_First != _Last)
			{
				do
				{
					<Module>.std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020&>(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, ptr);
					ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr != _Last);
			}
			uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020> = *((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4);
			ptr2 = *((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>));
			throw;
		}
		<Module>.std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>);
		return ptr2;
	}

	// Token: 0x06000023 RID: 35 RVA: 0x00001A1C File Offset: 0x00000E1C
	internal unsafe static void std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}(_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *A_0;
		if (ptr2 != ptr)
		{
			do
			{
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.__delDtor(ptr2, 0U);
				ptr2 += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (ptr2 != ptr);
		}
	}

	// Token: 0x06000024 RID: 36 RVA: 0x00001A48 File Offset: 0x00000E48
	internal unsafe static void std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}(unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>* A_0)
	{
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			<Module>.delete(num, 4U);
		}
	}

	// Token: 0x06000025 RID: 37 RVA: 0x00001A64 File Offset: 0x00000E64
	internal unsafe static duration<__int64,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000>,0>(duration<__int64,std::ratio<1,1000000000>\u0020>* A_0, duration<__int64,std::ratio<1,1000>\u0020>* _Dur)
	{
		*(long*)A_0 = *_Dur * 1000000L;
		return A_0;
	}

	// Token: 0x06000026 RID: 38 RVA: 0x000025C0 File Offset: 0x000019C0
	[return: MarshalAs(UnmanagedType.U1)]
	internal unsafe static bool std._To_xtime_10_day_clamped<__int64,struct\u0020std::ratio<1,1000000000>\u0020>(xtime* _Xt, duration<__int64,std::ratio<1,1000000000>\u0020>* _Rel_time)
	{
		duration<double,std::ratio<1,1>\u0020> duration<double,std::ratio<1,1>_u0020> = 864000.0;
		duration<__int64,std::ratio<1,10000000>\u0020> duration<__int64,std::ratio<1,10000000>_u0020> = <Module>._Xtime_get_ticks();
		duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>;
		duration<__int64,std::ratio<1,1000000000>\u0020>* ptr = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,10000000>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>, ref duration<__int64,std::ratio<1,10000000>_u0020>);
		duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>2 = *ptr;
		bool flag = <Module>.std.chrono.operator<<double,struct\u0020std::ratio<1,1>,__int64,struct\u0020std::ratio<1,1000000000>\u0020>(ref duration<double,std::ratio<1,1>_u0020>, _Rel_time);
		if (flag != null)
		{
			duration<__int64,std::ratio<1,1000000000>_u0020>2 += 864000000000000L;
		}
		else
		{
			duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>3;
			duration<__int64,std::ratio<1,1000000000>\u0020>* ptr2 = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>3, _Rel_time);
			duration<__int64,std::ratio<1,1000000000>_u0020>2 += *ptr2;
		}
		duration<__int64,std::ratio<1,1>\u0020> duration<__int64,std::ratio<1,1>_u0020>;
		<Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>((duration<__int64,std::ratio<1,1>\u0020>*)(&duration<__int64,std::ratio<1,1>_u0020>), ref duration<__int64,std::ratio<1,1000000000>_u0020>2);
		*_Xt = duration<__int64,std::ratio<1,1>_u0020>;
		duration<__int64,std::ratio<1,1000000000>\u0020> duration<__int64,std::ratio<1,1000000000>_u0020>4;
		duration<__int64,std::ratio<1,1000000000>\u0020>* ptr3 = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1>,0>(&duration<__int64,std::ratio<1,1000000000>_u0020>4, ref duration<__int64,std::ratio<1,1>_u0020>);
		duration<__int64,std::ratio<1,1000000000>_u0020>2 -= *ptr3;
		*(_Xt + 8) = duration<__int64,std::ratio<1,1000000000>_u0020>2;
		return flag;
	}

	// Token: 0x06000027 RID: 39 RVA: 0x000015D4 File Offset: 0x000009D4
	internal unsafe static duration<__int64,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1>,0>(duration<__int64,std::ratio<1,1000000000>\u0020>* A_0, duration<__int64,std::ratio<1,1>\u0020>* _Dur)
	{
		*(long*)A_0 = *_Dur * 1000000000L;
		return A_0;
	}

	// Token: 0x06000028 RID: 40 RVA: 0x0000203C File Offset: 0x0000143C
	internal unsafe static unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>* std.make_unique<class\u0020std::tuple<void\u0020(__cdecl*)(void)>,void\u0020(__cdecl&)(void),0>(unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>* A_0, delegate* unmanaged[Cdecl, Cdecl]<void> <_Args_0>)
	{
		uint num = 0U;
		tuple<void\u0020(__cdecl*)(void)>* ptr = <Module>.@new(4U);
		tuple<void\u0020(__cdecl*)(void)>* ptr2;
		if (ptr != null)
		{
			*(int*)ptr = <_Args_0>;
			ptr2 = ptr;
		}
		else
		{
			ptr2 = null;
		}
		*(int*)A_0 = ptr2;
		try
		{
			num = 1U;
		}
		catch
		{
			if ((num & 1U) != 0U)
			{
				num &= 4294967294U;
				<Module>.___CxxCallUnwindDtor(ldftn(std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}), (void*)A_0);
			}
			throw;
		}
		return A_0;
	}

	// Token: 0x06000029 RID: 41 RVA: 0x0000209C File Offset: 0x0000149C
	internal unsafe static uint std.thread._Invoke<class\u0020std::tuple<void\u0020(__cdecl*)(void)>,0>(void* _RawVals)
	{
		unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020> unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>;
		<Module>.std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.__autoclassinit2(ref unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>, 4U);
		unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020> = _RawVals;
		try
		{
			calli(System.Void modopt(System.Runtime.CompilerServices.CallConvCdecl)(), (IntPtr)(*unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>));
			<Module>._Cnd_do_broadcast_at_thread_exit();
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}), (void*)(&unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>));
			throw;
		}
		<Module>.std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.{dtor}(ref unique_ptr<std::tuple<void_u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void_u0020(__cdecl*)(void)>_u0020>_u0020>);
		return 0;
	}

	// Token: 0x0600002A RID: 42 RVA: 0x0000282C File Offset: 0x00001C2C
	internal unsafe static void std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020&>(_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* <_Vals_0>)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
		*(int*)ptr = 0;
		try
		{
			*(int*)(ptr + 16 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
			*(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), (void*)ptr);
			throw;
		}
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Construct_lv_contents(ptr, <_Vals_0>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr);
			throw;
		}
		*(A_0 + 4) = *(A_0 + 4) + 24;
	}

	// Token: 0x0600002B RID: 43 RVA: 0x000020F8 File Offset: 0x000014F8
	[return: MarshalAs(UnmanagedType.U1)]
	internal unsafe static bool std.chrono.operator<<double,struct\u0020std::ratio<1,1>,__int64,struct\u0020std::ratio<1,1000000000>\u0020>(duration<double,std::ratio<1,1>\u0020>* _Left, duration<__int64,std::ratio<1,1000000000>\u0020>* _Right)
	{
		duration<double,std::ratio<1,1000000000>\u0020> duration<double,std::ratio<1,1000000000>_u0020>;
		double num = *<Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<double,struct\u0020std::ratio<1,1000000000>\u0020>,double,struct\u0020std::ratio<1,1>,0>(&duration<double,std::ratio<1,1000000000>_u0020>, _Left);
		duration<double,std::ratio<1,1000000000>\u0020> duration<double,std::ratio<1,1000000000>_u0020>2;
		duration<double,std::ratio<1,1000000000>\u0020>* ptr = <Module>.std.chrono.duration_cast<class\u0020std::chrono::duration<double,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>(&duration<double,std::ratio<1,1000000000>_u0020>2, _Right);
		return (num >= *ptr) ? 0 : 1;
	}

	// Token: 0x0600002C RID: 44 RVA: 0x000015F0 File Offset: 0x000009F0
	internal unsafe static duration<__int64,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>(duration<__int64,std::ratio<1,1000000000>\u0020>* A_0, duration<__int64,std::ratio<1,1000000000>\u0020>* _Dur)
	{
		*(long*)A_0 = *_Dur;
		return A_0;
	}

	// Token: 0x0600002D RID: 45 RVA: 0x00001604 File Offset: 0x00000A04
	internal unsafe static duration<__int64,std::ratio<1,1>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>(duration<__int64,std::ratio<1,1>\u0020>* A_0, duration<__int64,std::ratio<1,1000000000>\u0020>* _Dur)
	{
		*(long*)A_0 = *_Dur / 1000000000L;
		return A_0;
	}

	// Token: 0x0600002E RID: 46 RVA: 0x00001638 File Offset: 0x00000A38
	internal unsafe static duration<__int64,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<__int64,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,10000000>,0>(duration<__int64,std::ratio<1,1000000000>\u0020>* A_0, duration<__int64,std::ratio<1,10000000>\u0020>* _Dur)
	{
		*(long*)A_0 = *_Dur * 100L;
		return A_0;
	}

	// Token: 0x0600002F RID: 47 RVA: 0x00001A80 File Offset: 0x00000E80
	internal unsafe static duration<double,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<double,struct\u0020std::ratio<1,1000000000>\u0020>,double,struct\u0020std::ratio<1,1>,0>(duration<double,std::ratio<1,1000000000>\u0020>* A_0, duration<double,std::ratio<1,1>\u0020>* _Dur)
	{
		*(double*)A_0 = *_Dur * 1000000000.0;
		return A_0;
	}

	// Token: 0x06000030 RID: 48 RVA: 0x00001A9C File Offset: 0x00000E9C
	internal unsafe static duration<double,std::ratio<1,1000000000>\u0020>* std.chrono.duration_cast<class\u0020std::chrono::duration<double,struct\u0020std::ratio<1,1000000000>\u0020>,__int64,struct\u0020std::ratio<1,1000000000>,0>(duration<double,std::ratio<1,1000000000>\u0020>* A_0, duration<__int64,std::ratio<1,1000000000>\u0020>* _Dur)
	{
		*(double*)A_0 = (double)(*_Dur);
		return A_0;
	}

	// Token: 0x06000031 RID: 49 RVA: 0x000038D4 File Offset: 0x00002CD4
	internal unsafe static void* std._Ref_count_base._Get_deleter(_Ref_count_base* A_0, type_info* A_0)
	{
		return 0;
	}

	// Token: 0x06000032 RID: 50 RVA: 0x00001650 File Offset: 0x00000A50
	internal unsafe static void std._Ref_count_base.{dtor}(_Ref_count_base* A_0)
	{
	}

	// Token: 0x06000033 RID: 51 RVA: 0x00001AB0 File Offset: 0x00000EB0
	internal unsafe static void std._Ref_count_base._Decref(_Ref_count_base* A_0)
	{
		if (Interlocked.Decrement(A_0 + 4) == 0)
		{
			calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.IntPtr), A_0, (IntPtr)(*(*A_0)));
			if (Interlocked.Decrement(A_0 + 8) == 0)
			{
				calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.IntPtr), A_0, (IntPtr)(*(*A_0 + 4)));
			}
		}
	}

	// Token: 0x06000034 RID: 52 RVA: 0x00001660 File Offset: 0x00000A60
	internal static uint msclr.interop.details.GetAnsiStringSize(string _str)
	{
		ref byte ptr = _str;
		if ((ref ptr) != null)
		{
			ptr = RuntimeHelpers.OffsetToStringData + (ref ptr);
		}
		ref char ptr2 = ref ptr;
		uint num = <Module>.WideCharToMultiByte(3U, 1024, ref ptr2, _str.Length, null, 0, null, null);
		if (num == 0U && _str.Length != 0)
		{
			throw new ArgumentException("Conversion from WideChar to MultiByte failed.  Please check the content of the string and/or locale settings.");
		}
		return num + 1U;
	}

	// Token: 0x06000035 RID: 53 RVA: 0x00001C68 File Offset: 0x00001068
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Eos(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint _Newsize)
	{
		sbyte* ptr = A_0;
		if (((16 <= *(A_0 + 20)) ? 1 : 0) != 0)
		{
			ptr = *A_0;
		}
		*(A_0 + 16) = _Newsize;
		*(byte*)(ptr + _Newsize / sizeof(sbyte)) = 0;
	}

	// Token: 0x06000036 RID: 54 RVA: 0x000026E0 File Offset: 0x00001AE0
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Reallocate_grow_by<class\u0020<lambda_b520e6e7dd2c85f4b83ca9ec1210796f>,unsigned\u0020int,char>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint _Size_increase, <lambda_b520e6e7dd2c85f4b83ca9ec1210796f> _Fn, uint <_Args_0>, sbyte <_Args_1>)
	{
		uint num = *(A_0 + 16);
		if (<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(A_0) - num < _Size_increase)
		{
			<Module>.std._Xlen_string();
		}
		uint num2 = num + _Size_increase;
		uint num3 = *(A_0 + 20);
		uint num4 = <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(A_0);
		uint num5 = (uint)(*(A_0 + 20));
		uint num6 = <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Calculate_growth(num2, num5, num4);
		uint num7 = num6 + 1;
		void* ptr;
		if (num7 >= 4096)
		{
			ptr = <Module>.std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(num7);
		}
		else if (num7 != null)
		{
			ptr = <Module>.@new(num7);
		}
		else
		{
			ptr = null;
		}
		*(A_0 + 16) = num2;
		*(A_0 + 20) = num6;
		if (16 <= num3)
		{
			sbyte* ptr2 = *A_0;
			cpblk(ptr, ptr2, num);
			initblk(num + (byte*)ptr, <_Args_1>, <_Args_0>);
			((byte*)(num + (byte*)ptr))[<_Args_0>] = 0;
			uint num8 = num3 + 1;
			void* ptr3 = ptr2;
			if (num8 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr3, ref num8);
			}
			<Module>.delete(ptr3, num8);
			*A_0 = ptr;
		}
		else
		{
			cpblk(ptr, A_0, num);
			int num9 = num + (byte*)ptr;
			initblk(num9, <_Args_1>, <_Args_0>);
			*(num9 + (int)<_Args_0>) = 0;
			*A_0 = ptr;
		}
		return A_0;
	}

	// Token: 0x06000037 RID: 55 RVA: 0x00002908 File Offset: 0x00001D08
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.append(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint _Count, sbyte _Ch)
	{
		uint num = *(A_0 + 16);
		uint num2 = (uint)(*(A_0 + 20));
		if (_Count <= num2 - num)
		{
			*(A_0 + 16) = num + _Count;
			sbyte* ptr = A_0;
			if (((16U <= num2) ? 1 : 0) != 0)
			{
				ptr = *A_0;
			}
			int num3 = num / sizeof(sbyte) + ptr;
			initblk(num3, _Ch, _Count);
			*(num3 + _Count) = 0;
			return A_0;
		}
		<lambda_b520e6e7dd2c85f4b83ca9ec1210796f> <lambda_b520e6e7dd2c85f4b83ca9ec1210796f>;
		initblk(ref <lambda_b520e6e7dd2c85f4b83ca9ec1210796f>, 0, 1);
		return <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Reallocate_grow_by<class\u0020<lambda_b520e6e7dd2c85f4b83ca9ec1210796f>,unsigned\u0020int,char>(A_0, _Count, <lambda_b520e6e7dd2c85f4b83ca9ec1210796f>, _Count, _Ch);
	}

	// Token: 0x06000038 RID: 56 RVA: 0x000016AC File Offset: 0x00000AAC
	internal unsafe static void msclr.interop.details.WriteAnsiString(sbyte* _buf, uint _size, string _str)
	{
		ref byte ptr = _str;
		if ((ref ptr) != null)
		{
			ptr = RuntimeHelpers.OffsetToStringData + (ref ptr);
		}
		ref char ptr2 = ref ptr;
		if (_size > 2147483647U)
		{
			throw new ArgumentOutOfRangeException("Size of string exceeds INT_MAX.");
		}
		uint num = <Module>.WideCharToMultiByte(3U, 1024, ref ptr2, _str.Length, _buf, (int)_size, null, null);
		if (num < _size && (num != null || _size == 1U))
		{
			*(byte*)(num / sizeof(sbyte) + _buf) = 0;
			return;
		}
		throw new ArgumentException("Conversion from WideChar to MultiByte failed.  Please check the content of the string and/or locale settings.");
	}

	// Token: 0x06000039 RID: 57 RVA: 0x000029E8 File Offset: 0x00001DE8
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* msclr.interop.marshal_as<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>,class\u0020System::String\u0020^>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, string* _from_obj)
	{
		try
		{
			uint num = 0U;
			if (*_from_obj == null)
			{
				throw new ArgumentNullException("NULLPTR is not supported for this conversion.");
			}
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}(A_0);
			num = 1U;
			uint num2 = <Module>.msclr.interop.details.GetAnsiStringSize(*_from_obj);
			if (num2 > 1U)
			{
				uint num3 = num2 - 1U;
				uint num4 = *(int*)(A_0 + 16 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>));
				if (num3 <= num4)
				{
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Eos(A_0, num3);
				}
				else
				{
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.append(A_0, num3 - num4, 0);
				}
				sbyte* ptr = (sbyte*)A_0;
				if (((16 <= *(int*)(A_0 + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>))) ? 1 : 0) != 0)
				{
					ptr = *(int*)A_0;
				}
				<Module>.msclr.interop.details.WriteAnsiString(ptr, num2, *_from_obj);
			}
		}
		catch
		{
			uint num;
			if ((num & 1U) != 0U)
			{
				num &= 4294967294U;
				<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)A_0);
			}
			throw;
		}
		return A_0;
	}

	// Token: 0x0600003A RID: 58 RVA: 0x00002164 File Offset: 0x00001564
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0)
	{
		*A_0 = 0;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2;
		try
		{
			ptr = A_0 + 16;
			*ptr = 0;
			ptr2 = A_0 + 20;
			*ptr2 = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), A_0);
			throw;
		}
		try
		{
			*ptr = 0;
			*ptr2 = 15;
			*A_0 = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x0600003B RID: 59 RVA: 0x00001C98 File Offset: 0x00001098
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Right)
	{
		cpblk(A_0, _Right, 24);
		*(_Right + 16) = 0;
		*(_Right + 20) = 15;
		*_Right = 0;
	}

	// Token: 0x0600003C RID: 60 RVA: 0x00001C18 File Offset: 0x00001018
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0)
	{
		uint num = (uint)(*(A_0 + 20));
		if (((16U <= num) ? 1 : 0) != 0)
		{
			uint num2 = num + 1U;
			void* ptr = *A_0;
			if (num2 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr, ref num2);
			}
			<Module>.delete(ptr, num2);
		}
		*(A_0 + 16) = 0;
		*(A_0 + 20) = 15;
		*A_0 = 0;
	}

	// Token: 0x0600003D RID: 61 RVA: 0x00002124 File Offset: 0x00001524
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0)
	{
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(A_0);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
	}

	// Token: 0x0600003E RID: 62 RVA: 0x00001B14 File Offset: 0x00000F14
	internal unsafe static _String_val<std::_Simple_types<char>\u0020>* std._String_val<std::_Simple_types<char>\u0020>.{ctor}(_String_val<std::_Simple_types<char>\u0020>* A_0)
	{
		*A_0 = 0;
		try
		{
			*(A_0 + 16) = 0;
			*(A_0 + 20) = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x0600003F RID: 63 RVA: 0x00001710 File Offset: 0x00000B10
	internal unsafe static void std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}(_String_val<std::_Simple_types<char>\u0020>._Bxty* A_0)
	{
	}

	// Token: 0x06000040 RID: 64 RVA: 0x00001C08 File Offset: 0x00001008
	internal unsafe static void std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}(_Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>* A_0)
	{
	}

	// Token: 0x06000041 RID: 65 RVA: 0x00001620 File Offset: 0x00000A20
	internal unsafe static void std._Xlen_string()
	{
		<Module>.std._Xlength_error((sbyte*)(&<Module>.??_C@_0BA@JFNIOLAK@string?5too?5long@));
	}

	// Token: 0x06000042 RID: 66 RVA: 0x00001720 File Offset: 0x00000B20
	internal unsafe static uint std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Calculate_growth(uint _Requested, uint _Old, uint _Max)
	{
		uint num = _Requested | 15;
		if (num > _Max)
		{
			return _Max;
		}
		uint num2 = _Old >> 1;
		if (_Old > _Max - num2)
		{
			return _Max;
		}
		uint num3 = _Old + num2;
		uint num4 = num3;
		return *(ref num < num3 ? ref num4 : ref num);
	}

	// Token: 0x06000043 RID: 67 RVA: 0x00001CBC File Offset: 0x000010BC
	internal unsafe static uint std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0)
	{
		return int.MaxValue;
	}

	// Token: 0x06000044 RID: 68 RVA: 0x000021E4 File Offset: 0x000015E4
	internal unsafe static uint std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Calculate_growth(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint _Requested)
	{
		uint num = <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(A_0);
		uint num2 = (uint)(*(A_0 + 20));
		uint num3 = _Requested | 15;
		uint num4;
		if (num3 > num)
		{
			num4 = num;
		}
		else
		{
			uint num5 = num2 >> 1;
			if (num2 > num - num5)
			{
				num4 = num;
			}
			else
			{
				uint num6 = num2 + num5;
				uint num7 = num6;
				num4 = (uint)(*(ref num3 < num6 ? ref num7 : ref num3));
			}
		}
		return num4;
	}

	// Token: 0x06000045 RID: 69 RVA: 0x000014F8 File Offset: 0x000008F8
	internal unsafe static bad_array_new_length* std.bad_array_new_length.{ctor}(bad_array_new_length* A_0)
	{
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		bad_array_new_length* ptr = A_0 + 4;
		initblk(ptr, 0, 8);
		*ptr = ref <Module>.??_C@_0BF@KINCDENJ@bad?5array?5new?5length@;
		try
		{
			*A_0 = ref <Module>.??_7bad_alloc@std@@6B@;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.exception.{dtor}), A_0);
			throw;
		}
		try
		{
			*A_0 = ref <Module>.??_7bad_array_new_length@std@@6B@;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.bad_alloc.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x06000046 RID: 70 RVA: 0x000037C0 File Offset: 0x00002BC0
	internal unsafe static void std.bad_array_new_length.{dtor}(bad_array_new_length* A_0)
	{
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
	}

	// Token: 0x06000047 RID: 71 RVA: 0x00003768 File Offset: 0x00002B68
	internal unsafe static void* std.bad_array_new_length.__vecDelDtor(bad_array_new_length* A_0, uint A_0)
	{
		if ((A_0 & 2U) != 0U)
		{
			bad_array_new_length* ptr = A_0 - 4;
			<Module>.__ehvec_dtor(A_0, 12U, (uint)(*ptr), ldftn(std.bad_array_new_length.{dtor}));
			if ((A_0 & 1U) != 0U)
			{
				bad_array_new_length* ptr2 = ptr;
				<Module>.delete[](ptr2, (uint)(*ptr2 * 12 + 4));
			}
			return ptr;
		}
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
		if ((A_0 & 1U) != 0U)
		{
			<Module>.delete(A_0, 12U);
		}
		return A_0;
	}

	// Token: 0x06000048 RID: 72 RVA: 0x000014DC File Offset: 0x000008DC
	internal unsafe static void std.bad_alloc.{dtor}(bad_alloc* A_0)
	{
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
	}

	// Token: 0x06000049 RID: 73 RVA: 0x00003708 File Offset: 0x00002B08
	internal unsafe static void* std.bad_alloc.__vecDelDtor(bad_alloc* A_0, uint A_0)
	{
		if ((A_0 & 2U) != 0U)
		{
			bad_alloc* ptr = A_0 - 4;
			<Module>.__ehvec_dtor(A_0, 12U, (uint)(*ptr), ldftn(std.bad_alloc.{dtor}));
			if ((A_0 & 1U) != 0U)
			{
				bad_alloc* ptr2 = ptr;
				<Module>.delete[](ptr2, (uint)(*ptr2 * 12 + 4));
			}
			return ptr;
		}
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
		if ((A_0 & 1U) != 0U)
		{
			<Module>.delete(A_0, 12U);
		}
		return A_0;
	}

	// Token: 0x0600004A RID: 74 RVA: 0x000014C0 File Offset: 0x000008C0
	internal unsafe static void std.exception.{dtor}(exception* A_0)
	{
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
	}

	// Token: 0x0600004B RID: 75 RVA: 0x000036A8 File Offset: 0x00002AA8
	internal unsafe static void* std.exception.__vecDelDtor(exception* A_0, uint A_0)
	{
		if ((A_0 & 2U) != 0U)
		{
			exception* ptr = A_0 - 4;
			<Module>.__ehvec_dtor(A_0, 12U, (uint)(*ptr), ldftn(std.exception.{dtor}));
			if ((A_0 & 1U) != 0U)
			{
				exception* ptr2 = ptr;
				<Module>.delete[](ptr2, (uint)(*ptr2 * 12 + 4));
			}
			return ptr;
		}
		*A_0 = ref <Module>.??_7exception@std@@6B@;
		<Module>.__std_exception_destroy(A_0 + 4);
		if ((A_0 & 1U) != 0U)
		{
			<Module>.delete(A_0, 12U);
		}
		return A_0;
	}

	// Token: 0x0600004C RID: 76 RVA: 0x00001580 File Offset: 0x00000980
	internal unsafe static void std._Throw_bad_array_new_length()
	{
		bad_array_new_length bad_array_new_length;
		<Module>.std.bad_array_new_length.{ctor}(ref bad_array_new_length);
		<Module>._CxxThrowException((void*)(&bad_array_new_length), (_s__ThrowInfo*)(&<Module>._TI3?AVbad_array_new_length@std@@));
	}

	// Token: 0x0600004D RID: 77 RVA: 0x00001758 File Offset: 0x00000B58
	internal unsafe static void* std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(uint _Bytes)
	{
		uint num = _Bytes + 35;
		if (num <= _Bytes)
		{
			<Module>.std._Throw_bad_array_new_length();
		}
		uint num2 = <Module>.@new(num);
		if (num2 != null)
		{
			void* ptr = (num2 + 35) & -32;
			*(ptr - 4) = num2;
			return ptr;
		}
		<Module>._invalid_parameter_noinfo_noreturn();
		return 0;
	}

	// Token: 0x0600004E RID: 78 RVA: 0x000015A4 File Offset: 0x000009A4
	internal unsafe static void std._Adjust_manually_vector_aligned(void** _Ptr, uint* _Bytes)
	{
		*_Bytes += 35;
		int num = *_Ptr;
		uint num2 = *(num - 4);
		if (num - num2 - 4 <= 31)
		{
			*_Ptr = num2;
		}
		else
		{
			<Module>._invalid_parameter_noinfo_noreturn();
		}
	}

	// Token: 0x0600004F RID: 79 RVA: 0x00001AE8 File Offset: 0x00000EE8
	internal unsafe static void std.allocator<char>.deallocate(allocator<char>* A_0, sbyte* _Ptr, uint _Count)
	{
		uint num = _Count;
		void* ptr = _Ptr;
		if (_Count >= 4096)
		{
			<Module>.std._Adjust_manually_vector_aligned(ref ptr, ref num);
		}
		<Module>.delete(ptr, num);
	}

	// Token: 0x06000050 RID: 80 RVA: 0x0000264C File Offset: 0x00001A4C
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Reallocate_for<class\u0020<lambda_88acb98cb1d3e807ff08d7ebe077788e>,char\u0020const\u0020*>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint _New_size, <lambda_88acb98cb1d3e807ff08d7ebe077788e> _Fn, sbyte* <_Args_0>)
	{
		if (_New_size > <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.max_size(A_0))
		{
			<Module>.std._Xlen_string();
		}
		uint num = *(A_0 + 20);
		uint num2 = <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Calculate_growth(A_0, _New_size);
		uint num3 = num2 + 1;
		void* ptr;
		if (num3 >= 4096)
		{
			ptr = <Module>.std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(num3);
		}
		else if (num3 != null)
		{
			ptr = <Module>.@new(num3);
		}
		else
		{
			ptr = null;
		}
		*(A_0 + 16) = _New_size;
		*(A_0 + 20) = num2;
		cpblk(ptr, <_Args_0>, _New_size);
		((byte*)ptr)[_New_size] = 0;
		if (16 <= num)
		{
			uint num4 = num + 1;
			void* ptr2 = *A_0;
			if (num4 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr2, ref num4);
			}
			<Module>.delete(ptr2, num4);
			*A_0 = ptr;
		}
		else
		{
			*A_0 = ptr;
		}
		return A_0;
	}

	// Token: 0x06000051 RID: 81 RVA: 0x000028B4 File Offset: 0x00001CB4
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.assign(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, sbyte* _Ptr, uint _Count)
	{
		uint num = (uint)(*(A_0 + 20));
		if (_Count <= num)
		{
			sbyte* ptr = A_0;
			if (((16U <= num) ? 1 : 0) != 0)
			{
				ptr = *A_0;
			}
			*(A_0 + 16) = _Count;
			<Module>.memmove((void*)ptr, _Ptr, _Count);
			*(byte*)(ptr + _Count / sizeof(sbyte)) = 0;
			return A_0;
		}
		<lambda_88acb98cb1d3e807ff08d7ebe077788e> <lambda_88acb98cb1d3e807ff08d7ebe077788e>;
		initblk(ref <lambda_88acb98cb1d3e807ff08d7ebe077788e>, 0, 1);
		return <Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Reallocate_for<class\u0020<lambda_88acb98cb1d3e807ff08d7ebe077788e>,char\u0020const\u0020*>(A_0, _Count, <lambda_88acb98cb1d3e807ff08d7ebe077788e>, _Ptr);
	}

	// Token: 0x06000052 RID: 82 RVA: 0x000038F0 File Offset: 0x00002CF0
	[return: MarshalAs(UnmanagedType.U1)]
	internal unsafe static bool IsWindowsVersionOrGreater(ushort wMajorVersion, ushort wMinorVersion, ushort wServicePackMajor)
	{
		_OSVERSIONINFOEXW osversioninfoexw = 284;
		*((ref osversioninfoexw) + 4) = 0;
		*((ref osversioninfoexw) + 8) = 0;
		*((ref osversioninfoexw) + 12) = 0;
		*((ref osversioninfoexw) + 16) = 0;
		initblk((ref osversioninfoexw) + 20, 0, 256);
		*((ref osversioninfoexw) + 276) = 0;
		initblk((ref osversioninfoexw) + 278, 0, 6);
		ulong num = <Module>.VerSetConditionMask(<Module>.VerSetConditionMask(<Module>.VerSetConditionMask(0UL, 2, 3), 1, 3), 32, 3);
		*((ref osversioninfoexw) + 4) = (int)wMajorVersion;
		*((ref osversioninfoexw) + 8) = (int)wMinorVersion;
		*((ref osversioninfoexw) + 276) = (short)wServicePackMajor;
		return (<Module>.VerifyVersionInfoW(&osversioninfoexw, 35, num) != 0) ? 1 : 0;
	}

	// Token: 0x06000053 RID: 83 RVA: 0x00003EB4 File Offset: 0x000032B4
	internal unsafe static int MasterHardDiskSerial.ReadPhysicalDriveInNTUsingSmart(MasterHardDiskSerial* A_0)
	{
		int num = 0;
		$ArrayType$$$BY0BAA@D $ArrayType$$$BY0BAA@D;
		<Module>.sprintf_s(ref $ArrayType$$$BY0BAA@D, 256, ref <Module>.??_C@_0BE@JBDFGGOO@?2?2?4?2PhysicalDrive?$CFd@, __arglist(0));
		void* ptr = <Module>.CreateFileA((sbyte*)(&$ArrayType$$$BY0BAA@D), -1073741824, 7, null, 3, 0, null);
		if (ptr == -1)
		{
			uint num2 = 256;
			MasterHardDiskSerial* ptr2 = A_0 + 2048;
			sbyte* ptr3 = ptr2;
			do
			{
				*(byte*)ptr3 = 0;
				ptr3 += 1 / sizeof(sbyte);
				num2--;
			}
			while (num2 != null);
			<Module>.sprintf_s(ptr2, 256, ref <Module>.??_C@_0GG@CJCAMLAA@?$CFd?5ReadPhysicalDriveInNTUsingSm@, __arglist(129, (sbyte*)(&$ArrayType$$$BY0BAA@D), <Module>.GetLastError()));
		}
		else
		{
			uint num3 = 0;
			_GETVERSIONINPARAMS getversioninparams;
			initblk(ref getversioninparams, 0, 24);
			if (<Module>.DeviceIoControl(ptr, 475264, null, 0, (void*)(&getversioninparams), 24, &num3, null) == null)
			{
				uint lastError = <Module>.GetLastError();
				uint num4 = 256;
				sbyte* ptr4 = A_0 + 2048;
				do
				{
					*(byte*)ptr4 = 0;
					ptr4 += 1 / sizeof(sbyte);
					num4--;
				}
				while (num4 != null);
				<Module>.sprintf_s(A_0 + 2048, 256, ref <Module>.??_C@_0GJ@IJMKHJPN@?6?$CFd?5ReadPhysicalDriveInNTUsingS@, __arglist(147, ptr, lastError));
			}
			else
			{
				_SENDCMDINPARAMS* ptr5 = <Module>.malloc(545U);
				*(byte*)(ptr5 + 10 / sizeof(_SENDCMDINPARAMS)) = 236;
				uint num5 = 0;
				if (<Module>.DeviceIoControl(ptr, 508040, (void*)ptr5, 33, (void*)ptr5, 545, &num5, null) == null)
				{
					uint num6 = 256;
					sbyte* ptr6 = A_0 + 2048;
					do
					{
						*(byte*)ptr6 = 0;
						ptr6 += 1 / sizeof(sbyte);
						num6--;
					}
					while (num6 != null);
					<Module>.sprintf_s(A_0 + 2048, 256, ref <Module>.??_C@_0BL@BENLMPB@SMART_RCV_DRIVE_DATA?5IOCTL@, __arglist());
				}
				else
				{
					ushort* ptr7 = (ushort*)(ptr5 + 16 / sizeof(_SENDCMDINPARAMS));
					int num7 = 0;
					$ArrayType$$$BY0BAA@K $ArrayType$$$BY0BAA@K;
					do
					{
						*(num7 * 4 + (ref $ArrayType$$$BY0BAA@K)) = (int)num7[ptr7];
						num7++;
					}
					while (num7 < 256);
					<Module>.MasterHardDiskSerial.PrintIdeInfo(A_0, 0, ref $ArrayType$$$BY0BAA@K);
					num = 1;
				}
				<Module>.CloseHandle(ptr);
				<Module>.free((void*)ptr5);
			}
		}
		return num;
	}

	// Token: 0x06000054 RID: 84 RVA: 0x00003988 File Offset: 0x00002D88
	internal unsafe static sbyte* MasterHardDiskSerial.flipAndCodeBytes(MasterHardDiskSerial* A_0, int iPos, int iFlip, sbyte* pcStr, sbyte* pcBuf)
	{
		*(byte*)pcBuf = 0;
		if (iPos <= 0)
		{
			return pcBuf;
		}
		sbyte b = 0;
		int num = 0;
		*(byte*)pcBuf = 0;
		int num2 = pcStr + iPos / sizeof(sbyte);
		int num3 = num2;
		for (;;)
		{
			sbyte b2 = *num3;
			if (b2 == 0)
			{
				goto IL_00E9;
			}
			sbyte b3 = <Module>.tolower((int)b2);
			b3 = ((<Module>.isspace(b3) != 0) ? 48 : b3);
			b++;
			sbyte b4 = (sbyte)(*(sbyte*)(pcBuf + num / sizeof(sbyte)) << 4);
			*(byte*)(pcBuf + num / sizeof(sbyte)) = (byte)b4;
			if (b3 + 208 <= 9)
			{
				*(byte*)(pcBuf + num / sizeof(sbyte)) = (b3 - 48) | b4;
			}
			else
			{
				if (b3 + 159 > 5)
				{
					break;
				}
				*(byte*)(pcBuf + num / sizeof(sbyte)) = (b3 - 87) | b4;
			}
			if (b == 2)
			{
				sbyte b5 = *(sbyte*)(pcBuf + num / sizeof(sbyte));
				if (b5 != 0 && <Module>.isprint((int)b5) == null)
				{
					break;
				}
				num++;
				b = 0;
				*(byte*)(num / sizeof(sbyte) + pcBuf) = 0;
			}
			num3++;
		}
		num = 0;
		int num4 = num2;
		for (;;)
		{
			sbyte b6 = *num4;
			if (b6 == 0)
			{
				goto IL_00E9;
			}
			sbyte b7 = b6;
			if (<Module>.isprint(b7) == null)
			{
				break;
			}
			*(byte*)(num / sizeof(sbyte) + pcBuf) = b7;
			num++;
			num4++;
		}
		num = 0;
		IL_00E9:
		*(byte*)(num / sizeof(sbyte) + pcBuf) = 0;
		int num5;
		if (iFlip != 0)
		{
			num5 = 0;
			if (0 < num)
			{
				do
				{
					sbyte b8 = *(sbyte*)(pcBuf + num5 / sizeof(sbyte));
					*(byte*)(pcBuf + num5 / sizeof(sbyte)) = (byte)(*(sbyte*)(pcBuf + num5 / sizeof(sbyte) + 1 / sizeof(sbyte)));
					*(byte*)(pcBuf + num5 / sizeof(sbyte) + 1 / sizeof(sbyte)) = b8;
					num5 += 2;
				}
				while (num5 < num);
			}
		}
		num5 = -1;
		int num6 = -1;
		num = 0;
		if (*(sbyte*)pcBuf != 0)
		{
			do
			{
				if (<Module>.isspace((int)(*(sbyte*)(num / sizeof(sbyte) + pcBuf))) == null)
				{
					num6 = ((num6 < 0) ? num : num6);
					num5 = num;
				}
				num++;
			}
			while (*(sbyte*)(num / sizeof(sbyte) + pcBuf) != 0);
			if (num6 >= 0 && num5 >= 0)
			{
				num = num6;
				if (num6 <= num5)
				{
					int num7 = pcBuf - num6 / sizeof(sbyte);
					do
					{
						sbyte b9 = *(sbyte*)(num / sizeof(sbyte) + pcBuf);
						if (b9 == 0)
						{
							break;
						}
						*(num7 + num) = (byte)b9;
						num++;
					}
					while (num <= num5);
				}
				*(byte*)((num - num6) / sizeof(sbyte) + pcBuf) = 0;
			}
		}
		return pcBuf;
	}

	// Token: 0x06000055 RID: 85 RVA: 0x00003B18 File Offset: 0x00002F18
	internal unsafe static int MasterHardDiskSerial.ReadPhysicalDriveInNTWithZeroRights(MasterHardDiskSerial* A_0)
	{
		int num = 0;
		$ArrayType$$$BY0BAA@D $ArrayType$$$BY0BAA@D;
		<Module>.sprintf_s(ref $ArrayType$$$BY0BAA@D, 256, ref <Module>.??_C@_0BE@JBDFGGOO@?2?2?4?2PhysicalDrive?$CFd@, __arglist(0));
		void* ptr = <Module>.CreateFileA((sbyte*)(&$ArrayType$$$BY0BAA@D), 0, 3, null, 3, 0, null);
		if (ptr == -1)
		{
			uint num2 = 256;
			MasterHardDiskSerial* ptr2 = A_0 + 2048;
			sbyte* ptr3 = ptr2;
			do
			{
				*(byte*)ptr3 = 0;
				ptr3 += 1 / sizeof(sbyte);
				num2--;
			}
			while (num2 != null);
			<Module>.sprintf_s(ptr2, 256, ref <Module>.??_C@_0FL@JJOBKBEG@?$CFd?5ReadPhysicalDriveInNTWithZer@, __arglist(325, (sbyte*)(&$ArrayType$$$BY0BAA@D)));
		}
		else
		{
			uint num3 = 0;
			_STORAGE_PROPERTY_QUERY storage_PROPERTY_QUERY;
			initblk(ref storage_PROPERTY_QUERY, 0, 12);
			storage_PROPERTY_QUERY = 0;
			*((ref storage_PROPERTY_QUERY) + 4) = 0;
			$ArrayType$$$BY0CHBA@D $ArrayType$$$BY0CHBA@D;
			initblk(ref $ArrayType$$$BY0CHBA@D, 0, 10000);
			if (<Module>.DeviceIoControl(ptr, 2954240, (void*)(&storage_PROPERTY_QUERY), 12, (void*)(&$ArrayType$$$BY0CHBA@D), 10000, &num3, null) != null)
			{
				$ArrayType$$$BY0DOI@D $ArrayType$$$BY0DOI@D;
				<Module>.MasterHardDiskSerial.flipAndCodeBytes(A_0, *((ref $ArrayType$$$BY0CHBA@D) + 12), 0, (sbyte*)(&$ArrayType$$$BY0CHBA@D), (sbyte*)(&$ArrayType$$$BY0DOI@D));
				$ArrayType$$$BY0DOI@D $ArrayType$$$BY0DOI@D2;
				<Module>.MasterHardDiskSerial.flipAndCodeBytes(A_0, *((ref $ArrayType$$$BY0CHBA@D) + 16), 0, (sbyte*)(&$ArrayType$$$BY0CHBA@D), (sbyte*)(&$ArrayType$$$BY0DOI@D2));
				$ArrayType$$$BY0DOI@D $ArrayType$$$BY0DOI@D3;
				<Module>.MasterHardDiskSerial.flipAndCodeBytes(A_0, *((ref $ArrayType$$$BY0CHBA@D) + 20), 0, (sbyte*)(&$ArrayType$$$BY0CHBA@D), (sbyte*)(&$ArrayType$$$BY0DOI@D3));
				$ArrayType$$$BY0DOI@D $ArrayType$$$BY0DOI@D4;
				<Module>.MasterHardDiskSerial.flipAndCodeBytes(A_0, *((ref $ArrayType$$$BY0CHBA@D) + 24), 0, (sbyte*)(&$ArrayType$$$BY0CHBA@D), (sbyte*)(&$ArrayType$$$BY0DOI@D4));
				if (0 == *A_0 && (<Module>.iswalnum((ushort)$ArrayType$$$BY0DOI@D4) != null || <Module>.iswalnum((ushort)((int)(*((ref $ArrayType$$$BY0DOI@D4) + 19)))) != null))
				{
					<Module>.strcpy_s(A_0, 1024U, (sbyte*)(&$ArrayType$$$BY0DOI@D4));
					<Module>.strcpy_s(A_0 + 1024, 1024U, (sbyte*)(&$ArrayType$$$BY0DOI@D2));
					num = 1;
				}
				initblk(ref $ArrayType$$$BY0CHBA@D, 0, 10000);
				if (<Module>.DeviceIoControl(ptr, 458912, null, 0, (void*)(&$ArrayType$$$BY0CHBA@D), 10000, &num3, null) == null)
				{
					uint num4 = 256;
					sbyte* ptr4 = A_0 + 2048;
					do
					{
						*(byte*)ptr4 = 0;
						ptr4 += 1 / sizeof(sbyte);
						num4--;
					}
					while (num4 != null);
					<Module>.sprintf_s<256>(A_0 + 2048, (sbyte*)(&<Module>.??_C@_0GN@GPCACGJP@?$CFs?5ReadPhysicalDriveInNTWithZer@), __arglist((sbyte*)(&$ArrayType$$$BY0BAA@D)));
				}
			}
			else
			{
				uint lastError = <Module>.GetLastError();
				uint num5 = 256;
				sbyte* ptr5 = A_0 + 2048;
				do
				{
					*(byte*)ptr5 = 0;
					ptr5 += 1 / sizeof(sbyte);
					num5--;
				}
				while (num5 != null);
				<Module>.sprintf_s<256>(A_0 + 2048, (sbyte*)(&<Module>.??_C@_0DJ@LJNAKKAB@DeviceIOControl?5IOCTL_STORAGE_Q@), __arglist(lastError));
			}
			<Module>.CloseHandle(ptr);
		}
		return num;
	}

	// Token: 0x06000056 RID: 86 RVA: 0x00003E14 File Offset: 0x00003214
	internal unsafe static void MasterHardDiskSerial.PrintIdeInfo(MasterHardDiskSerial* A_0, int iDrive, uint* dwDiskdata)
	{
		$ArrayType$$$BY0EAA@D $ArrayType$$$BY0EAA@D;
		<Module>.MasterHardDiskSerial.ConvertToString(A_0, dwDiskdata, 10, 19, (sbyte*)(&$ArrayType$$$BY0EAA@D));
		$ArrayType$$$BY0EAA@D $ArrayType$$$BY0EAA@D2;
		<Module>.MasterHardDiskSerial.ConvertToString(A_0, dwDiskdata, 27, 46, (sbyte*)(&$ArrayType$$$BY0EAA@D2));
		$ArrayType$$$BY0EAA@D $ArrayType$$$BY0EAA@D3;
		<Module>.MasterHardDiskSerial.ConvertToString(A_0, dwDiskdata, 23, 26, (sbyte*)(&$ArrayType$$$BY0EAA@D3));
		$ArrayType$$$BY0CA@D $ArrayType$$$BY0CA@D;
		<Module>.sprintf_s(ref $ArrayType$$$BY0CA@D, 32, ref <Module>.??_C@_02GMHACPFF@?$CFu@, __arglist(*(dwDiskdata + 84) * 512));
		if (0 == *A_0 && (<Module>.isalnum($ArrayType$$$BY0EAA@D) != null || <Module>.isalnum((int)(*((ref $ArrayType$$$BY0EAA@D) + 19))) != null))
		{
			<Module>.strcpy_s(A_0, 1024U, (sbyte*)(&$ArrayType$$$BY0EAA@D));
			<Module>.strcpy_s(A_0 + 1024, 1024U, (sbyte*)(&$ArrayType$$$BY0EAA@D2));
		}
	}

	// Token: 0x06000057 RID: 87 RVA: 0x00004054 File Offset: 0x00003454
	internal unsafe static int MasterHardDiskSerial.getHardDriveComputerID(MasterHardDiskSerial* A_0)
	{
		long num = 0L;
		<Module>.strcpy_s(A_0, 1024U, (sbyte*)(&<Module>.??_C@_00CNPNBAHC@@));
		if (<Module>.IsWindowsVersionOrGreater(5, 1, 0) != null && <Module>.MasterHardDiskSerial.ReadPhysicalDriveInNTWithZeroRights(A_0) == null)
		{
			<Module>.MasterHardDiskSerial.ReadPhysicalDriveInNTUsingSmart(A_0);
		}
		if (*A_0 > 0)
		{
			sbyte* ptr = A_0;
			if (<Module>.strncmp(A_0, (sbyte*)(&<Module>.??_C@_04GCPHMKHD@WD?9W@), 4U) == null)
			{
				ptr = A_0 + 5;
			}
			if (ptr != null)
			{
				do
				{
					sbyte b = *(sbyte*)ptr;
					if (b == 0)
					{
						break;
					}
					if (45 != b)
					{
						num *= 10L;
						switch (b)
						{
						case 49:
							num += 1L;
							break;
						case 50:
							num += 2L;
							break;
						case 51:
							num += 3L;
							break;
						case 52:
							num += 4L;
							break;
						case 53:
							num += 5L;
							break;
						case 54:
							num += 6L;
							break;
						case 55:
							num += 7L;
							break;
						case 56:
							num += 8L;
							break;
						case 57:
							num += 9L;
							break;
						case 65:
						case 97:
							num += 10L;
							break;
						case 66:
						case 98:
							num += 11L;
							break;
						case 67:
						case 99:
							num += 12L;
							break;
						case 68:
						case 100:
							num += 13L;
							break;
						case 69:
						case 101:
							num += 14L;
							break;
						case 70:
						case 102:
							num += 15L;
							break;
						case 71:
						case 103:
							num += 16L;
							break;
						case 72:
						case 104:
							num += 17L;
							break;
						case 73:
						case 105:
							num += 18L;
							break;
						case 74:
						case 106:
							num += 19L;
							break;
						case 75:
						case 107:
							num += 20L;
							break;
						case 76:
						case 108:
							num += 21L;
							break;
						case 77:
						case 109:
							num += 22L;
							break;
						case 78:
						case 110:
							num += 23L;
							break;
						case 79:
						case 111:
							num += 24L;
							break;
						case 80:
						case 112:
							num += 25L;
							break;
						case 81:
						case 113:
							num += 26L;
							break;
						case 82:
						case 114:
							num += 27L;
							break;
						case 83:
						case 115:
							num += 28L;
							break;
						case 84:
						case 116:
							num += 29L;
							break;
						case 85:
						case 117:
							num += 30L;
							break;
						case 86:
						case 118:
							num += 31L;
							break;
						case 87:
						case 119:
							num += 32L;
							break;
						case 88:
						case 120:
							num += 33L;
							break;
						case 89:
						case 121:
							num += 34L;
							break;
						case 90:
						case 122:
							num += 35L;
							break;
						}
					}
					ptr += 1 / sizeof(sbyte);
				}
				while (ptr != null);
			}
		}
		long num2 = num;
		num = num2 + num2 / -100000000L * 100000000L;
		MasterHardDiskSerial* ptr2 = A_0 + 1024;
		if (<Module>.strstr(ptr2, (sbyte*)(&<Module>.??_C@_04FELOGBA@IBM?9@)) != null)
		{
			num += 300000000L;
		}
		else if (<Module>.strstr(ptr2, (sbyte*)(&<Module>.??_C@_06DMAMAECF@MAXTOR@)) == null && <Module>.strstr(ptr2, (sbyte*)(&<Module>.??_C@_06PHJKODGL@Maxtor@)) == null)
		{
			if (<Module>.strstr(ptr2, (sbyte*)(&<Module>.??_C@_04EAMAMDGI@WDC?5@)) != null)
			{
				num += 500000000L;
			}
			else
			{
				num += 600000000L;
			}
		}
		else
		{
			num += 400000000L;
		}
		return (int)num;
	}

	// Token: 0x06000058 RID: 88 RVA: 0x00004648 File Offset: 0x00003A48
	internal unsafe static int MasterHardDiskSerial.GetSerialNo(MasterHardDiskSerial* A_0, vector<char,std::allocator<char>\u0020>* serialNumber)
	{
		<Module>.MasterHardDiskSerial.getHardDriveComputerID(A_0);
		MasterHardDiskSerial* ptr = A_0;
		if (*A_0 != 0)
		{
			do
			{
				ptr++;
			}
			while (*ptr != 0);
		}
		uint num = ptr - A_0;
		if (num == 0U)
		{
			return -1;
		}
		_Value_init_tag value_init_tag;
		<Module>.std.vector<char,std::allocator<char>\u0020>._Resize<struct\u0020std::_Value_init_tag>(serialNumber, num, ref value_init_tag);
		int num2 = *serialNumber;
		cpblk(num2, A_0, *(serialNumber + 4) - num2);
		return 0;
	}

	// Token: 0x06000059 RID: 89 RVA: 0x00003CFC File Offset: 0x000030FC
	internal unsafe static sbyte* MasterHardDiskSerial.ConvertToString(MasterHardDiskSerial* A_0, uint* dwDiskdata, int iFirstIndex, int iLastIndex, sbyte* pcBuf)
	{
		int num = 0;
		int num2 = iFirstIndex;
		if (iFirstIndex <= iLastIndex)
		{
			do
			{
				sbyte b = (uint)(*(num2 * 4 + dwDiskdata)) >> 8;
				$ArrayType$$$BY01D $ArrayType$$$BY01D = <Module>.??_C@_01CLKCMJKC@?5@;
				if (b != $ArrayType$$$BY01D)
				{
					*(byte*)(num / sizeof(sbyte) + pcBuf) = b;
					num++;
				}
				sbyte b2 = (sbyte)(*(num2 * 4 + dwDiskdata));
				if (b2 != $ArrayType$$$BY01D)
				{
					*(byte*)(num / sizeof(sbyte) + pcBuf) = b2;
					num++;
				}
				num2++;
			}
			while (num2 <= iLastIndex);
		}
		*(byte*)(num / sizeof(sbyte) + pcBuf) = 0;
		int num3 = num - 1;
		if (num3 > 0)
		{
			while (<Module>.isspace((int)(*(sbyte*)(pcBuf + num3 / sizeof(sbyte)))) != null)
			{
				*(byte*)(pcBuf + num3 / sizeof(sbyte)) = 0;
				num3--;
				if (num3 <= 0)
				{
					break;
				}
			}
		}
		return pcBuf;
	}

	// Token: 0x0600005A RID: 90 RVA: 0x00003D80 File Offset: 0x00003180
	internal unsafe static MasterHardDiskSerial* MasterHardDiskSerial.{ctor}(MasterHardDiskSerial* A_0)
	{
		uint num = 256;
		sbyte* ptr = A_0 + 2048;
		do
		{
			*(byte*)ptr = 0;
			ptr += 1 / sizeof(sbyte);
			num--;
		}
		while (num != null);
		uint num2 = 1024;
		sbyte* ptr2 = A_0 + 1024;
		do
		{
			*(byte*)ptr2 = 0;
			ptr2 += 1 / sizeof(sbyte);
			num2--;
		}
		while (num2 != null);
		uint num3 = 1024;
		sbyte* ptr3 = A_0;
		do
		{
			*(byte*)ptr3 = 0;
			ptr3 += 1 / sizeof(sbyte);
			num3--;
		}
		while (num3 != null);
		return A_0;
	}

	// Token: 0x0600005B RID: 91 RVA: 0x00003DEC File Offset: 0x000031EC
	internal unsafe static void MasterHardDiskSerial.{dtor}(MasterHardDiskSerial* A_0)
	{
	}

	// Token: 0x0600005C RID: 92 RVA: 0x000045F0 File Offset: 0x000039F0
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Resize<struct\u0020std::_Value_init_tag>(vector<char,std::allocator<char>\u0020>* A_0, uint _Newsize, _Value_init_tag* _Val)
	{
		uint num = (uint)(*(A_0 + 4));
		uint num2 = (uint)(*A_0);
		uint num3 = num - num2;
		if (_Newsize < num3)
		{
			*(A_0 + 4) = num2 + _Newsize;
		}
		else if (_Newsize > num3)
		{
			if (_Newsize > *(A_0 + 8) - (int)num2)
			{
				<Module>.std.vector<char,std::allocator<char>\u0020>._Resize_reallocate<struct\u0020std::_Value_init_tag>(A_0, _Newsize, _Val);
			}
			else
			{
				sbyte* ptr = num;
				_Value_init_tag value_init_tag = *_Val;
				*(A_0 + 4) = <Module>.std._Uninitialized_value_construct_n<class\u0020std::allocator<char>\u0020>(ptr, _Newsize - num3, A_0);
			}
		}
	}

	// Token: 0x0600005D RID: 93 RVA: 0x000043D4 File Offset: 0x000037D4
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Destroy(vector<char,std::allocator<char>\u0020>* A_0, sbyte* _First, sbyte* _Last)
	{
	}

	// Token: 0x0600005E RID: 94 RVA: 0x00003EA4 File Offset: 0x000032A4
	internal unsafe static allocator<char>* std.vector<char,std::allocator<char>\u0020>._Getal(vector<char,std::allocator<char>\u0020>* A_0)
	{
		return A_0;
	}

	// Token: 0x0600005F RID: 95 RVA: 0x0000449C File Offset: 0x0000389C
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Resize_reallocate<struct\u0020std::_Value_init_tag>(vector<char,std::allocator<char>\u0020>* A_0, uint _Newsize, _Value_init_tag* _Val)
	{
		int num = (int)stackalloc byte[<Module>.__CxxQueryExceptionSize()];
		if (_Newsize > 2147483647)
		{
			<Module>.std.vector<char,std::allocator<char>\u0020>._Xlength();
		}
		uint num2 = *(A_0 + 4) - *A_0;
		uint num3 = <Module>.std.vector<char,std::allocator<char>\u0020>._Calculate_growth(A_0, _Newsize);
		void* ptr;
		if (num3 >= 4096)
		{
			ptr = <Module>.std._Allocate_manually_vector_aligned<struct\u0020std::_Default_allocate_traits>(num3);
		}
		else if (num3 != null)
		{
			ptr = <Module>.@new(num3);
		}
		else
		{
			ptr = null;
		}
		sbyte* ptr2 = (byte*)ptr + num2;
		sbyte* ptr3 = ptr2;
		uint exceptionCode;
		try
		{
			_Value_init_tag value_init_tag = *_Val;
			ptr3 = <Module>.std._Uninitialized_value_construct_n<class\u0020std::allocator<char>\u0020>(ptr2, _Newsize - num2, A_0);
			sbyte* ptr4 = *(A_0 + 4);
			sbyte* ptr5 = *A_0;
			integral_constant<bool,1> integral_constant<bool,1>;
			initblk(ref integral_constant<bool,1>, 0, 1);
			integral_constant<bool,1> integral_constant<bool,1>2;
			cpblk(ref integral_constant<bool,1>2, ref integral_constant<bool,1>, 1);
			<Module>.std._Uninitialized_move<char\u0020*,class\u0020std::allocator<char>\u0020>(ptr5, ptr4, (sbyte*)ptr, A_0);
		}
		catch when (delegate
		{
			// Failed to create a 'catch-when' expression
			exceptionCode = (uint)Marshal.GetExceptionCode();
			endfilter(<Module>.__CxxExceptionFilter(Marshal.GetExceptionPointers(), null, 0, null) != null);
		})
		{
			uint num4 = 0U;
			<Module>.__CxxRegisterExceptionObject(Marshal.GetExceptionPointers(), num);
			try
			{
				try
				{
					<Module>.std.vector<char,std::allocator<char>\u0020>._Destroy(A_0, ptr2, ptr3);
					<Module>.std.allocator<char>.deallocate(<Module>.std.vector<char,std::allocator<char>\u0020>._Getal(A_0), ptr, num3);
					<Module>._CxxThrowException(null, null);
				}
				catch when (delegate
				{
					// Failed to create a 'catch-when' expression
					num4 = <Module>.__CxxDetectRethrow(Marshal.GetExceptionPointers());
					endfilter(num4 != 0U);
				})
				{
				}
				if (num4 != 0U)
				{
					throw;
				}
			}
			finally
			{
				<Module>.__CxxUnregisterExceptionObject(num, (int)num4);
			}
		}
		<Module>.std.vector<char,std::allocator<char>\u0020>._Change_array(A_0, ptr, _Newsize, num3);
	}

	// Token: 0x06000060 RID: 96 RVA: 0x0000444C File Offset: 0x0000384C
	internal unsafe static sbyte* std._Uninitialized_value_construct_n<class\u0020std::allocator<char>\u0020>(sbyte* _First, uint _Count, allocator<char>* _Al)
	{
		initblk(_First, 0, _Count);
		return _First + _Count / (uint)sizeof(sbyte);
	}

	// Token: 0x06000061 RID: 97 RVA: 0x00003DFC File Offset: 0x000031FC
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Xlength()
	{
		<Module>.std._Xlength_error((sbyte*)(&<Module>.??_C@_0BA@FOIKENOD@vector?5too?5long@));
	}

	// Token: 0x06000062 RID: 98 RVA: 0x000043E4 File Offset: 0x000037E4
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Change_array(vector<char,std::allocator<char>\u0020>* A_0, sbyte* _Newvec, uint _Newsize, uint _Newcapacity)
	{
		ref int ptr = A_0 + 4;
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			uint num2 = (uint)(*(A_0 + 8) - (int)num);
			void* ptr2 = num;
			if (num2 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr2, ref num2);
			}
			<Module>.delete(ptr2, num2);
		}
		*A_0 = _Newvec;
		ptr = _Newvec + _Newsize;
		*(A_0 + 8) = _Newvec + _Newcapacity;
	}

	// Token: 0x06000063 RID: 99 RVA: 0x00004464 File Offset: 0x00003864
	internal unsafe static uint std.vector<char,std::allocator<char>\u0020>._Calculate_growth(vector<char,std::allocator<char>\u0020>* A_0, uint _Newsize)
	{
		uint num = *(A_0 + 8) - *A_0;
		uint num2 = num >> 1;
		if (num > 2147483647U - num2)
		{
			return int.MaxValue;
		}
		uint num3 = num2 + num;
		return (num3 < _Newsize) ? _Newsize : num3;
	}

	// Token: 0x06000064 RID: 100 RVA: 0x0000442C File Offset: 0x0000382C
	internal unsafe static sbyte* std._Uninitialized_move<char\u0020*,class\u0020std::allocator<char>\u0020>(sbyte* _First, sbyte* _Last, sbyte* _Dest, allocator<char>* _Al)
	{
		int num = _Last - _First;
		<Module>.memmove((void*)_Dest, _First, (uint)num);
		return num / sizeof(sbyte) + _Dest;
	}

	// Token: 0x06000065 RID: 101 RVA: 0x00004D10 File Offset: 0x00004110
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* CDataStore.GetString(CDataStore* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_1)
	{
		try
		{
			uint num = 0U;
			int num2 = *(A_0 + 20);
			uint num3 = (uint)(*(*(A_0 + 4) + num2));
			*(A_0 + 20) = num2 + 4;
			sbyte* ptr = <Module>.new[](num3);
			delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, uint, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)*,System.UInt32) = <Module>.?fpGetString@CDataStore@@0P6EAAV1@PAV1@PADI@ZA;
			CDataStore* ptr2 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.SByte modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)*,System.UInt32), A_0, ptr, num3, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.SByte_u0020modopt(System.Runtime.CompilerServices.IsSignUnspecifiedByte)*,System.UInt32));
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}(A_1, ptr, num3);
			num = 1U;
			<Module>.delete[]((void*)ptr);
		}
		catch
		{
			uint num;
			if ((num & 1U) != 0U)
			{
				num &= 4294967294U;
				<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)A_1);
			}
			throw;
		}
		return A_1;
	}

	// Token: 0x06000066 RID: 102 RVA: 0x00005324 File Offset: 0x00004724
	internal unsafe static BannedProccesses* BannedProccesses.GetInstance()
	{
		<Module>._Init_thread_header_m((int*)(&<Module>.?$TSS0@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4HA));
		if (<Module>.?$TSS0@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4HA == -1)
		{
			try
			{
				initblk(ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A, 0, 36);
				<Module>.BannedProccesses.{ctor}(ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A);
				<Module>._atexit_m(ldftn(??__Finstance@?1??GetInstance@BannedProccesses@@SAAAV1@XZ@YMXXZ));
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(_Init_thread_abort_m), (void*)(&<Module>.?$TSS0@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4HA));
				throw;
			}
			<Module>._Init_thread_footer_m((int*)(&<Module>.?$TSS0@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4HA));
		}
		return ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A;
	}

	// Token: 0x06000067 RID: 103 RVA: 0x000053A4 File Offset: 0x000047A4
	internal unsafe static void BannedProccesses.SetProccess(BannedProccesses* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* proccesses)
	{
		@lock @lock = null;
		try
		{
			@lock lock2 = new @lock(lockRef._lockRef);
			try
			{
				@lock = lock2;
				if (A_0 != proccesses)
				{
					integral_constant<bool,0> integral_constant<bool,0>;
					initblk(ref integral_constant<bool,0>, 0, 1);
					<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Copy_assign(A_0, proccesses, integral_constant<bool,0>);
				}
				BannedProccessesManaged.GetInstance().SetNormalizedManagedProccesses(proccesses);
			}
			catch
			{
				((IDisposable)@lock).Dispose();
				throw;
			}
			((IDisposable)@lock).Dispose();
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)proccesses);
			throw;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(proccesses);
	}

	// Token: 0x06000068 RID: 104 RVA: 0x0000543C File Offset: 0x0000483C
	internal unsafe static void BannedProccesses.SetModules(BannedProccesses* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* modules)
	{
		@lock @lock = null;
		try
		{
			@lock lock2 = new @lock(lockRef._lockRef);
			try
			{
				@lock = lock2;
				vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr = A_0 + 12;
				if (ptr != modules)
				{
					integral_constant<bool,0> integral_constant<bool,0>;
					initblk(ref integral_constant<bool,0>, 0, 1);
					<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Copy_assign(ptr, modules, integral_constant<bool,0>);
				}
				BannedProccessesManaged.GetInstance().SetNormalizedManagedModules(modules);
			}
			catch
			{
				((IDisposable)@lock).Dispose();
				throw;
			}
			((IDisposable)@lock).Dispose();
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)modules);
			throw;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(modules);
	}

	// Token: 0x06000069 RID: 105 RVA: 0x000054D8 File Offset: 0x000048D8
	internal unsafe static void BannedProccesses.SetWindowTitles(BannedProccesses* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* titles)
	{
		@lock @lock = null;
		try
		{
			@lock lock2 = new @lock(lockRef._lockRef);
			try
			{
				@lock = lock2;
				vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr = A_0 + 24;
				if (ptr != titles)
				{
					integral_constant<bool,0> integral_constant<bool,0>;
					initblk(ref integral_constant<bool,0>, 0, 1);
					<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Copy_assign(ptr, titles, integral_constant<bool,0>);
				}
				BannedProccessesManaged.GetInstance().SetNormalizedManagedTitles(titles);
			}
			catch
			{
				((IDisposable)@lock).Dispose();
				throw;
			}
			((IDisposable)@lock).Dispose();
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)titles);
			throw;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(titles);
	}

	// Token: 0x0600006A RID: 106 RVA: 0x000085B8 File Offset: 0x000079B8
	internal unsafe static void ??__Finstance@?1??GetInstance@BannedProccesses@@SAAAV1@XZ@YMXXZ()
	{
		try
		{
			try
			{
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy((ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A) + 24);
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A) + 12);
				throw;
			}
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy((ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A) + 12);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&<Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A));
			throw;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(ref <Module>.?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A);
	}

	// Token: 0x0600006B RID: 107 RVA: 0x00005118 File Offset: 0x00004518
	internal unsafe static BannedProccesses* BannedProccesses.{ctor}(BannedProccesses* A_0)
	{
		*A_0 = 0;
		*(A_0 + 4) = 0;
		*(A_0 + 8) = 0;
		try
		{
			vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr = A_0 + 12;
			*ptr = 0;
			*(ptr + 4) = 0;
			*(ptr + 8) = 0;
			try
			{
				vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr2 = A_0 + 24;
				*ptr2 = 0;
				*(ptr2 + 4) = 0;
				*(ptr2 + 8) = 0;
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), A_0 + 12);
				throw;
			}
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x0600006C RID: 108 RVA: 0x00001000 File Offset: 0x00000400
	internal static void ?A0x347d919e.??__E?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A@@YMXXZ()
	{
		<Module>._atexit_m(ldftn(?A0x347d919e.??__F?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A@@YMXXZ));
	}

	// Token: 0x0600006D RID: 109 RVA: 0x00008594 File Offset: 0x00007994
	internal static void ?A0x347d919e.??__F?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A@@YMXXZ()
	{
		if (<Module>.?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A != null)
		{
			<Module>.delete(<Module>.?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A, 4U);
		}
	}

	// Token: 0x0600006E RID: 110 RVA: 0x0000101C File Offset: 0x0000041C
	internal unsafe static void ?A0x347d919e.??__E?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A@@YMXXZ()
	{
		<Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A = <Module>.phmap.priv.EmptyGroup();
		*((ref <Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A) + 4) = 0;
		*((ref <Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A) + 8) = 0;
		*((ref <Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A) + 12) = 0;
		*((ref <Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A) + 20) = 0;
		<Module>._atexit_m(ldftn(?A0x347d919e.??__F?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A@@YMXXZ));
	}

	// Token: 0x0600006F RID: 111 RVA: 0x00008648 File Offset: 0x00007A48
	internal static void ?A0x347d919e.??__F?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A@@YMXXZ()
	{
		<Module>.phmap.priv.raw_hash_set<phmap::priv::FlatHashMapPolicy<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>,phmap::Hash<enum\u0020GlobalOffsets>,phmap::EqualTo<enum\u0020GlobalOffsets>,std::allocator<std::pair<enum\u0020GlobalOffsets\u0020const\u0020,unsigned\u0020char\u0020*>\u0020>\u0020>.destroy_slots(ref <Module>.?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A);
	}

	// Token: 0x06000070 RID: 112 RVA: 0x000058FC File Offset: 0x00004CFC
	internal unsafe static int AnticheatInitializeHandler(void* param, Opcodes msgId, uint time, CDataStore* msg)
	{
		<Module>.SetMessageHandlers();
		vector<char,std::allocator<char>\u0020> vector<char,std::allocator<char>_u0020>;
		initblk(ref vector<char,std::allocator<char>_u0020>, 0, 12);
		vector<char,std::allocator<char>_u0020> = 0;
		*((ref vector<char,std::allocator<char>_u0020>) + 4) = 0;
		*((ref vector<char,std::allocator<char>_u0020>) + 8) = 0;
		try
		{
			MasterHardDiskSerial masterHardDiskSerial;
			<Module>.MasterHardDiskSerial.{ctor}(ref masterHardDiskSerial);
			try
			{
				<Module>.MasterHardDiskSerial.GetSerialNo(ref masterHardDiskSerial, ref vector<char,std::allocator<char>_u0020>);
				_Vector_iterator<std::_Vector_val<std::_Simple_types<char>\u0020>\u0020> vector_iterator<std::_Vector_val<std::_Simple_types<char>_u0020>_u0020> = *((ref vector<char,std::allocator<char>_u0020>) + 4);
				_Vector_iterator<std::_Vector_val<std::_Simple_types<char>\u0020>\u0020> vector_iterator<std::_Vector_val<std::_Simple_types<char>_u0020>_u0020>2 = vector<char,std::allocator<char>_u0020>;
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>;
				allocator<char> allocator<char>;
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}<class\u0020std::_Vector_iterator<class\u0020std::_Vector_val<struct\u0020std::_Simple_types<char>\u0020>\u0020>,0>(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>, vector_iterator<std::_Vector_val<std::_Simple_types<char>_u0020>_u0020>2, vector_iterator<std::_Vector_val<std::_Simple_types<char>_u0020>_u0020>, ref allocator<char>);
				try
				{
					CDataStore cdataStore;
					initblk(ref cdataStore, 0, 24);
					cdataStore = ref <Module>.??_7CDataStore@@6B@;
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpInit@CDataStore@@0P6EPAV1@PAV1@@ZA;
					CDataStore* ptr = calli(CDataStore* modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, cdataStore*_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32) = <Module>.?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;
					CDataStore* ptr2 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.Int32), &cdataStore, 1312, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32));
					try
					{
						delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32)2 = <Module>.?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;
						CDataStore* ptr3 = calli(CDataStore* modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced) modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*,System.Int32), &cdataStore, 4, cdataStore*_u0020modopt(System.Runtime.CompilerServices.IsImplicitlyDereferenced)_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*,System.Int32)2);
						<Module>.CDataStore.PutString(ref cdataStore, ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
						delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*) = <Module>.?fpFinalize@CDataStore@@0P6EXPAV1@@ZA;
						calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*));
						delegate* unmanaged[Thiscall, Thiscall]<void*, CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*) = <Module>.?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA;
						calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(System.Void*,CDataStore*), calli(System.Void* modopt(System.Runtime.CompilerServices.CallConvCdecl)(), <Module>.?fpGetCurrent@ClientServices@@0P6APAXXZA), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(System.Void*,CDataStore*));
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(CDataStore.{dtor}), (void*)(&cdataStore));
						throw;
					}
					cdataStore = ref <Module>.??_7CDataStore@@6B@;
					delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2 = <Module>.?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;
					calli(System.Void modopt(System.Runtime.CompilerServices.CallConvThiscall)(CDataStore*), &cdataStore, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvThiscall)_u0020(CDataStore*)2);
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
					throw;
				}
				try
				{
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
					throw;
				}
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(MasterHardDiskSerial.{dtor}), (void*)(&masterHardDiskSerial));
				throw;
			}
			<Module>.MasterHardDiskSerial.{dtor}(ref masterHardDiskSerial);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<char,std::allocator<char>\u0020>.{dtor}), (void*)(&vector<char,std::allocator<char>_u0020>));
			throw;
		}
		<Module>.std.vector<char,std::allocator<char>\u0020>._Tidy(ref vector<char,std::allocator<char>_u0020>);
		return 1;
	}

	// Token: 0x06000071 RID: 113 RVA: 0x00005574 File Offset: 0x00004974
	internal unsafe static int AnticheatBannedProcessListHandler(void* param, Opcodes msgId, uint time, CDataStore* msg)
	{
		int num = *(int*)(msg + 20 / sizeof(CDataStore));
		uint num2 = (uint)(*(num + *(int*)(msg + 4 / sizeof(CDataStore))));
		*(int*)(msg + 20 / sizeof(CDataStore)) = num + 4;
		vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>;
		initblk(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, 0, 12);
		vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020> = 0;
		*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4) = 0;
		*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 8) = 0;
		try
		{
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.reserve(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, num2);
			if (0U < num2)
			{
				uint num3 = num2;
				do
				{
					basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>;
					basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = <Module>.CDataStore.GetString(msg, &basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
					try
					{
						<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, ptr);
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
						throw;
					}
					try
					{
						<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>);
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>));
						throw;
					}
					num3 -= 1U;
				}
				while (num3 > 0U);
			}
			int num4 = *(int*)(msg + 20 / sizeof(CDataStore));
			uint num5 = (uint)(*(num4 + *(int*)(msg + 4 / sizeof(CDataStore))));
			*(int*)(msg + 20 / sizeof(CDataStore)) = num4 + 4;
			vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2;
			initblk(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2, 0, 12);
			vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2 = 0;
			*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2) + 4) = 0;
			*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2) + 8) = 0;
			try
			{
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.reserve(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2, num5);
				if (0U < num5)
				{
					uint num6 = num5;
					do
					{
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2;
						basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = <Module>.CDataStore.GetString(msg, &basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2);
						try
						{
							<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2, ptr2);
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2));
							throw;
						}
						try
						{
							<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2);
						}
						catch
						{
							<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>2));
							throw;
						}
						num6 -= 1U;
					}
					while (num6 > 0U);
				}
				int num7 = *(int*)(msg + 20 / sizeof(CDataStore));
				uint num8 = (uint)(*(num7 + *(int*)(msg + 4 / sizeof(CDataStore))));
				*(int*)(msg + 20 / sizeof(CDataStore)) = num7 + 4;
				vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3;
				initblk(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3, 0, 12);
				vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3 = 0;
				*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3) + 4) = 0;
				*((ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3) + 8) = 0;
				try
				{
					<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.reserve(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3, num8);
					if (0U < num8)
					{
						uint num9 = num8;
						do
						{
							basic_string<char,std::char_traits<char>,std::allocator<char>\u0020> basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3;
							basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr3 = <Module>.CDataStore.GetString(msg, &basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3);
							try
							{
								<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3, ptr3);
							}
							catch
							{
								<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3));
								throw;
							}
							try
							{
								<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ref basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3);
							}
							catch
							{
								<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)(&basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>3));
								throw;
							}
							num9 -= 1U;
						}
						while (num9 > 0U);
					}
					BannedProccesses* ptr4 = <Module>.BannedProccesses.GetInstance();
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>4;
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr5 = <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{ctor}(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>4, ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>);
					<Module>.BannedProccesses.SetProccess(ptr4, ptr5);
					BannedProccesses* ptr6 = <Module>.BannedProccesses.GetInstance();
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>5;
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr7 = <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{ctor}(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>5, ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2);
					<Module>.BannedProccesses.SetModules(ptr6, ptr7);
					BannedProccesses* ptr8 = <Module>.BannedProccesses.GetInstance();
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>6;
					vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* ptr9 = <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{ctor}(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>6, ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3);
					<Module>.BannedProccesses.SetWindowTitles(ptr8, ptr9);
					AntiCheatService antiCheatService;
					<Module>.AntiCheatService.DetectHackProcesses(ref antiCheatService, true, false);
					<Module>.AntiCheatService.DetectHackModules(ref antiCheatService, true, false);
					<Module>.AntiCheatService.DetectHackTitles(ref antiCheatService, true, false);
					<Module>.AntiCheatService.DetectDebugger(ref antiCheatService);
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3));
					throw;
				}
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>3);
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2));
				throw;
			}
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>2);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>));
			throw;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(ref vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>);
		return 1;
	}

	// Token: 0x06000072 RID: 114 RVA: 0x000058BC File Offset: 0x00004CBC
	internal unsafe static void SetMessageHandlers()
	{
		delegate* unmanaged[Cdecl, Cdecl]<Opcodes, delegate* unmanaged[Cdecl, Cdecl]<void*, Opcodes, uint, CDataStore*, int>, void*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(Opcodes,System.Int32_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*) = <Module>.?fpSetMessageHandler@ClientServices@@0P6AXW4Opcodes@@P6AHPAX0IPAVCDataStore@@@Z1@ZA;
		calli(System.Void modopt(System.Runtime.CompilerServices.CallConvCdecl)(Opcodes,System.Int32 modopt(System.Runtime.CompilerServices.CallConvCdecl) (System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*), (Opcodes)14, <Module>.__unep@?AnticheatInitializeHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z, -559039810, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(Opcodes,System.Int32_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*));
		delegate* unmanaged[Cdecl, Cdecl]<Opcodes, delegate* unmanaged[Cdecl, Cdecl]<void*, Opcodes, uint, CDataStore*, int>, void*, void> system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(Opcodes,System.Int32_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*)2 = <Module>.?fpSetMessageHandler@ClientServices@@0P6AXW4Opcodes@@P6AHPAX0IPAVCDataStore@@@Z1@ZA;
		calli(System.Void modopt(System.Runtime.CompilerServices.CallConvCdecl)(Opcodes,System.Int32 modopt(System.Runtime.CompilerServices.CallConvCdecl) (System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*), (Opcodes)35, <Module>.__unep@?AnticheatBannedProcessListHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z, -559039810, system.Void_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(Opcodes,System.Int32_u0020modopt(System.Runtime.CompilerServices.CallConvCdecl)_u0020(System.Void*,Opcodes,System.UInt32,CDataStore*),System.Void*)2);
	}

	// Token: 0x06000073 RID: 115 RVA: 0x000048A0 File Offset: 0x00003CA0
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>.{dtor}(vector<char,std::allocator<char>\u0020>* A_0)
	{
		<Module>.std.vector<char,std::allocator<char>\u0020>._Tidy(A_0);
	}

	// Token: 0x06000074 RID: 116 RVA: 0x00001A48 File Offset: 0x00000E48
	internal unsafe static void std.unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>.{dtor}(unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>* A_0)
	{
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			<Module>.delete(num, 4U);
		}
	}

	// Token: 0x06000075 RID: 117 RVA: 0x000052D8 File Offset: 0x000046D8
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.reserve(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint _Newcapacity)
	{
		if (_Newcapacity > (*(A_0 + 8) - *A_0) / 24)
		{
			if (_Newcapacity > 178956970)
			{
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Xlength();
			}
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Reallocate_exactly(A_0, _Newcapacity);
		}
	}

	// Token: 0x06000076 RID: 118 RVA: 0x000051AC File Offset: 0x000045AC
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* <_Val_0>)
	{
		uint num = (uint)(*(A_0 + 4));
		if (num != (uint)(*(A_0 + 8)))
		{
			return <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back_with_unused_capacity<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(A_0, <_Val_0>);
		}
		int num2 = (int)num;
		return <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_reallocate<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(A_0, num2, <_Val_0>);
	}

	// Token: 0x06000077 RID: 119 RVA: 0x00004988 File Offset: 0x00003D88
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back_with_unused_capacity<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* <_Val_0>)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
		*(int*)ptr = 0;
		try
		{
			*(int*)(ptr + 16 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
			*(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), (void*)ptr);
			throw;
		}
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(ptr, <_Val_0>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr);
			throw;
		}
		int num = *(A_0 + 4);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = num;
		*(A_0 + 4) = num + 24;
		return ptr2;
	}

	// Token: 0x06000078 RID: 120 RVA: 0x00004E74 File Offset: 0x00004274
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0)
	{
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(A_0);
	}

	// Token: 0x06000079 RID: 121 RVA: 0x000047F0 File Offset: 0x00003BF0
	internal unsafe static vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{ctor}(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* _Right)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(_Right + 8);
		*(_Right + 8) = 0;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *(_Right + 4);
		*(_Right + 4) = 0;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr3 = *_Right;
		*_Right = 0;
		*A_0 = ptr3;
		*(A_0 + 4) = ptr2;
		*(A_0 + 8) = ptr;
		return A_0;
	}

	// Token: 0x0600007A RID: 122 RVA: 0x00004764 File Offset: 0x00003B64
	internal unsafe static _Ptr_base<ProcessDescription>* std._Ptr_base<ProcessDescription>.{ctor}(_Ptr_base<ProcessDescription>* A_0)
	{
		*A_0 = 0;
		*(A_0 + 4) = 0;
		return A_0;
	}

	// Token: 0x0600007B RID: 123 RVA: 0x00004828 File Offset: 0x00003C28
	internal unsafe static void std.vector<char,std::allocator<char>\u0020>._Tidy(vector<char,std::allocator<char>\u0020>* A_0)
	{
		sbyte** ptr = A_0 + 4;
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			uint num2 = (uint)(*(A_0 + 8) - (int)num);
			void* ptr2 = num;
			if (num2 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr2, ref num2);
			}
			<Module>.delete(ptr2, num2);
			*A_0 = 0;
			*ptr = 0;
			*(A_0 + 8) = 0;
		}
	}

	// Token: 0x0600007C RID: 124 RVA: 0x00004A48 File Offset: 0x00003E48
	internal unsafe static void phmap.priv.raw_hash_set<phmap::priv::FlatHashMapPolicy<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>,phmap::Hash<enum\u0020GlobalOffsets>,phmap::EqualTo<enum\u0020GlobalOffsets>,std::allocator<std::pair<enum\u0020GlobalOffsets\u0020const\u0020,unsigned\u0020char\u0020*>\u0020>\u0020>.destroy_slots(raw_hash_set<phmap::priv::FlatHashMapPolicy<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>,phmap::Hash<enum\u0020GlobalOffsets>,phmap::EqualTo<enum\u0020GlobalOffsets>,std::allocator<std::pair<enum\u0020GlobalOffsets\u0020const\u0020,unsigned\u0020char\u0020*>\u0020>\u0020>* A_0)
	{
		uint num = (uint)(*(A_0 + 12));
		if (num != 0U)
		{
			uint num2 = num;
			Layout<signed\u0020char,phmap::priv::map_slot_type<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>\u0020> layout<signed_u0020char,phmap::priv::map_slot_type<enum_u0020GlobalOffsets,unsigned_u0020char_u0020*>_u0020> = num2 + 17U;
			*((ref layout<signed_u0020char,phmap::priv::map_slot_type<enum_u0020GlobalOffsets,unsigned_u0020char_u0020*>_u0020>) + 4) = (int)num2;
			uint num3 = *((ref layout<signed_u0020char,phmap::priv::map_slot_type<enum_u0020GlobalOffsets,unsigned_u0020char_u0020*>_u0020>) + 4) * 8 + <Module>.phmap.priv.internal_layout.LayoutImpl<std::tuple<signed\u0020char,phmap::priv::map_slot_type<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>\u0020>,phmap::integer_sequence<unsigned\u0020int,0,1>,phmap::integer_sequence<unsigned\u0020int,0,1>\u0020>.Offset<1,0>(ref layout<signed_u0020char,phmap::priv::map_slot_type<enum_u0020GlobalOffsets,unsigned_u0020char_u0020*>_u0020>) + 3 >> 2 << 2;
			void* ptr = *A_0;
			if (num3 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr, ref num3);
			}
			<Module>.delete(ptr, num3);
			*A_0 = <Module>.phmap.priv.EmptyGroup();
			*(A_0 + 4) = 0;
			*(A_0 + 8) = 0;
			*(A_0 + 12) = 0;
			*(A_0 + 20) = 0;
		}
	}

	// Token: 0x0600007D RID: 125 RVA: 0x00003DFC File Offset: 0x000031FC
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Xlength()
	{
		<Module>.std._Xlength_error((sbyte*)(&<Module>.??_C@_0BA@FOIKENOD@vector?5too?5long@));
	}

	// Token: 0x0600007E RID: 126 RVA: 0x000051D8 File Offset: 0x000045D8
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Reallocate_exactly(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint _Newcapacity)
	{
		int num = (int)stackalloc byte[<Module>.__CxxQueryExceptionSize()];
		uint num2 = (*(A_0 + 4) - *A_0) / 24;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = <Module>.std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.allocate(A_0, _Newcapacity);
		uint exceptionCode;
		try
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = *(A_0 + 4);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr3 = *A_0;
			integral_constant<bool,1> integral_constant<bool,1>;
			initblk(ref integral_constant<bool,1>, 0, 1);
			integral_constant<bool,1> integral_constant<bool,1>2;
			cpblk(ref integral_constant<bool,1>2, ref integral_constant<bool,1>, 1);
			<Module>.std._Uninitialized_move<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(ptr3, ptr2, ptr, A_0);
		}
		catch when (delegate
		{
			// Failed to create a 'catch-when' expression
			exceptionCode = (uint)Marshal.GetExceptionCode();
			endfilter(<Module>.__CxxExceptionFilter(Marshal.GetExceptionPointers(), null, 0, null) != null);
		})
		{
			uint num3 = 0U;
			<Module>.__CxxRegisterExceptionObject(Marshal.GetExceptionPointers(), num);
			try
			{
				try
				{
					<Module>.std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.deallocate(<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Getal(A_0), ptr, _Newcapacity);
					<Module>._CxxThrowException(null, null);
				}
				catch when (delegate
				{
					// Failed to create a 'catch-when' expression
					num3 = <Module>.__CxxDetectRethrow(Marshal.GetExceptionPointers());
					endfilter(num3 != 0U);
				})
				{
				}
				if (num3 != 0U)
				{
					throw;
				}
			}
			finally
			{
				<Module>.__CxxUnregisterExceptionObject(num, (int)num3);
			}
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Change_array(A_0, ptr, num2, _Newcapacity);
	}

	// Token: 0x0600007F RID: 127 RVA: 0x00005308 File Offset: 0x00004708
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Copy_assign(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* _Right, integral_constant<bool,0> __unnamed001)
	{
		forward_iterator_tag forward_iterator_tag;
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Assign_range<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*>(A_0, *_Right, *(_Right + 4), forward_iterator_tag);
	}

	// Token: 0x06000080 RID: 128 RVA: 0x00004D9C File Offset: 0x0000419C
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Change_array(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Newvec, uint _Newsize, uint _Newcapacity)
	{
		uint num = (uint)(*A_0);
		if (num != 0U)
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = num;
			if (ptr2 != ptr)
			{
				do
				{
					try
					{
						<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr2);
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr2);
						throw;
					}
					ptr2 += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr2 != ptr);
			}
			num = (uint)(*A_0);
			uint num2 = (uint)((*(A_0 + 8) - (int)num) / 24 * 24);
			void* ptr3 = num;
			if (num2 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr3, ref num2);
			}
			<Module>.delete(ptr3, num2);
		}
		*A_0 = _Newvec;
		*(A_0 + 4) = _Newsize * 24 + _Newvec;
		*(A_0 + 8) = _Newcapacity * 24 + _Newvec;
	}

	// Token: 0x06000081 RID: 129 RVA: 0x00004B44 File Offset: 0x00003F44
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}<class\u0020std::_Vector_iterator<class\u0020std::_Vector_val<struct\u0020std::_Simple_types<char>\u0020>\u0020>,0>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, _Vector_iterator<std::_Vector_val<std::_Simple_types<char>\u0020>\u0020> _First, _Vector_iterator<std::_Vector_val<std::_Simple_types<char>\u0020>\u0020> _Last, allocator<char>* _Al)
	{
		*A_0 = 0;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2;
		try
		{
			ptr = A_0 + 16;
			*ptr = 0;
			ptr2 = A_0 + 20;
			*ptr2 = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), A_0);
			throw;
		}
		try
		{
			*ptr = 0;
			*ptr2 = 15;
			*A_0 = 0;
			if (_First != _Last)
			{
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.assign(A_0, _First, _Last - _First);
			}
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x06000082 RID: 130 RVA: 0x00004E88 File Offset: 0x00004288
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_reallocate<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Whereptr, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* <_Val_0>)
	{
		int num = (int)stackalloc byte[<Module>.__CxxQueryExceptionSize()];
		int num2 = *A_0;
		uint num3 = (_Whereptr - num2) / 24;
		uint num4 = (*(A_0 + 4) - num2) / 24;
		if (num4 == 178956970)
		{
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Xlength();
		}
		uint num5 = num4 + 1;
		uint num6 = <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Calculate_growth(A_0, num5);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = <Module>.std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.allocate(A_0, num6);
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = ptr + num3 * 24;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr3 = ptr2 + 24;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr4 = ptr3;
		uint exceptionCode;
		try
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr5 = ptr2;
			<Module>.std._String_val<std::_Simple_types<char>\u0020>.{ctor}(ptr2);
			try
			{
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(ptr2, <_Val_0>);
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr5);
				throw;
			}
			ptr4 = ptr2;
			int num7 = *(A_0 + 4);
			if (_Whereptr == num7)
			{
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr6 = num7;
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr7 = *A_0;
				integral_constant<bool,1> integral_constant<bool,1>;
				initblk(ref integral_constant<bool,1>, 0, 1);
				integral_constant<bool,1> integral_constant<bool,1>2;
				cpblk(ref integral_constant<bool,1>2, ref integral_constant<bool,1>, 1);
				<Module>.std._Uninitialized_move<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(ptr7, ptr6, ptr, A_0);
			}
			else
			{
				<Module>.std._Uninitialized_move<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(*A_0, _Whereptr, ptr, A_0);
				ptr4 = ptr;
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr8 = *(A_0 + 4);
				<Module>.std._Uninitialized_move<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(_Whereptr, ptr8, ptr2 + 24, A_0);
			}
		}
		catch when (delegate
		{
			// Failed to create a 'catch-when' expression
			exceptionCode = (uint)Marshal.GetExceptionCode();
			endfilter(<Module>.__CxxExceptionFilter(Marshal.GetExceptionPointers(), null, 0, null) != null);
		})
		{
			uint num8 = 0U;
			<Module>.__CxxRegisterExceptionObject(Marshal.GetExceptionPointers(), num);
			try
			{
				try
				{
					<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Destroy(A_0, ptr4, ptr3);
					<Module>.std.allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>.deallocate(A_0, ptr, num6);
					<Module>._CxxThrowException(null, null);
				}
				catch when (delegate
				{
					// Failed to create a 'catch-when' expression
					num8 = <Module>.__CxxDetectRethrow(Marshal.GetExceptionPointers());
					endfilter(num8 != 0U);
				})
				{
				}
				if (num8 != 0U)
				{
					throw;
				}
			}
			finally
			{
				<Module>.__CxxUnregisterExceptionObject(num, (int)num8);
			}
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Change_array(A_0, ptr, num5, num6);
		ptr2 = ptr + num3 * 24;
		return ptr2;
	}

	// Token: 0x06000083 RID: 131 RVA: 0x00004790 File Offset: 0x00003B90
	internal unsafe static uint phmap.priv.internal_layout.LayoutImpl<std::tuple<signed\u0020char,phmap::priv::map_slot_type<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>\u0020>,phmap::integer_sequence<unsigned\u0020int,0,1>,phmap::integer_sequence<unsigned\u0020int,0,1>\u0020>.Offset<1,0>(LayoutImpl<std::tuple<signed\u0020char,phmap::priv::map_slot_type<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*>\u0020>,phmap::integer_sequence<unsigned\u0020int,0,1>,phmap::integer_sequence<unsigned\u0020int,0,1>\u0020>* A_0)
	{
		return (*A_0 + 3) & -4;
	}

	// Token: 0x06000084 RID: 132 RVA: 0x00004BE0 File Offset: 0x00003FE0
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std._Uninitialized_move<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _First, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Last, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Dest, allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>* _Al)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = _First;
		_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020> uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>;
		initblk(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, 0, 12);
		uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020> = _Dest;
		*((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4) = _Dest;
		*((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 8) = _Al;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2;
		try
		{
			if (_First != _Last)
			{
				do
				{
					<Module>.std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>, ptr);
					ptr += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr != _Last);
			}
			uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020> = *((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4);
			ptr2 = *((ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>) + 4);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}), (void*)(&uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>));
			throw;
		}
		<Module>.std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{dtor}(ref uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>_u0020>_u0020>_u0020>);
		return ptr2;
	}

	// Token: 0x06000085 RID: 133 RVA: 0x00004764 File Offset: 0x00003B64
	internal unsafe static shared_ptr<ProcessDescription>* std.shared_ptr<ProcessDescription>.{ctor}(shared_ptr<ProcessDescription>* A_0)
	{
		*A_0 = 0;
		*(A_0 + 4) = 0;
		return A_0;
	}

	// Token: 0x06000086 RID: 134 RVA: 0x0000477C File Offset: 0x00003B7C
	internal unsafe static void std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.__autoclassinit2(_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint A_0)
	{
		initblk(A_0, 0, A_0);
	}

	// Token: 0x06000087 RID: 135 RVA: 0x000047A4 File Offset: 0x00003BA4
	internal unsafe static uint std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Calculate_growth(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint _Newsize)
	{
		uint num = (*(A_0 + 8) - *A_0) / 24;
		uint num2 = num >> 1;
		if (num > 178956970U - num2)
		{
			return 178956970;
		}
		uint num3 = num2 + num;
		return (num3 < _Newsize) ? _Newsize : num3;
	}

	// Token: 0x06000088 RID: 136 RVA: 0x0000504C File Offset: 0x0000444C
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Assign_range<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _First, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Last, forward_iterator_tag __unnamed002)
	{
		uint num = (_Last - _First) / 24;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>** ptr = A_0 + 8;
		int num2 = *A_0;
		uint num3 = (uint)((*(A_0 + 4) - num2) / 24);
		if (num > num3)
		{
			if (num > (*ptr - num2) / 24)
			{
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Clear_and_reserve_geometric(A_0, num);
				num3 = 0U;
			}
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = num3 * 24U / (uint)sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>) + _First;
			<Module>.std._Copy_unchecked<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*>(_First, ptr2, *A_0);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr3 = *(A_0 + 4);
			*(A_0 + 4) = <Module>.std._Uninitialized_copy<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::allocator<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>\u0020>(ptr2, _Last, ptr3, A_0);
		}
		else
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr4 = num * 24 + num2;
			<Module>.std._Copy_unchecked<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*>(_First, _Last, num2);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr5 = *(A_0 + 4);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr6 = ptr4;
			if (ptr4 != ptr5)
			{
				do
				{
					try
					{
						<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr6);
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr6);
						throw;
					}
					ptr6 += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr6 != ptr5);
			}
			*(A_0 + 4) = ptr4;
		}
	}

	// Token: 0x06000089 RID: 137 RVA: 0x000048B4 File Offset: 0x00003CB4
	internal unsafe static void std._Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Emplace_back<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020>(_Uninitialized_backout_al<std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* <_Vals_0>)
	{
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
		*(int*)ptr = 0;
		try
		{
			*(int*)(ptr + 16 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
			*(int*)(ptr + 20 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>)) = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), (void*)ptr);
			throw;
		}
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Take_contents(ptr, <_Vals_0>);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr);
			throw;
		}
		*(A_0 + 4) = *(A_0 + 4) + 24;
	}

	// Token: 0x0600008A RID: 138 RVA: 0x0000493C File Offset: 0x00003D3C
	internal unsafe static void* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.__delDtor(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, uint A_0)
	{
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(A_0);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
		if ((A_0 & 1U) != 0U)
		{
			<Module>.delete(A_0, 24U);
		}
		return A_0;
	}

	// Token: 0x0600008B RID: 139 RVA: 0x00005AD8 File Offset: 0x00004ED8
	internal unsafe static void* ProcessDescription.__delDtor(ProcessDescription* A_0, uint A_0)
	{
		<Module>.ProcessDescription.{dtor}(A_0);
		if ((A_0 & 1U) != 0U)
		{
			<Module>.delete(A_0, 76U);
		}
		return A_0;
	}

	// Token: 0x0600008C RID: 140 RVA: 0x00005AFC File Offset: 0x00004EFC
	internal unsafe static void ProcessDescription.{dtor}(ProcessDescription* A_0)
	{
		try
		{
			try
			{
				basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = A_0 + 48;
				try
				{
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr);
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), ptr);
					throw;
				}
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), A_0 + 24);
				throw;
			}
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = A_0 + 24;
			try
			{
				<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr2);
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), ptr2);
				throw;
			}
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{dtor}), A_0);
			throw;
		}
		try
		{
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(A_0);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
	}

	// Token: 0x0600008D RID: 141 RVA: 0x00004C60 File Offset: 0x00004060
	internal unsafe static void std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Clear_and_reserve_geometric(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, uint _Newsize)
	{
		if (_Newsize > 178956970)
		{
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Xlength();
		}
		uint num = <Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Calculate_growth(A_0, _Newsize);
		uint num2 = (uint)(*A_0);
		if (num2 != 0U)
		{
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr = *(A_0 + 4);
			basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2 = num2;
			if (ptr2 != ptr)
			{
				do
				{
					try
					{
						<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Tidy_deallocate(ptr2);
					}
					catch
					{
						<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), (void*)ptr2);
						throw;
					}
					ptr2 += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				}
				while (ptr2 != ptr);
			}
			num2 = (uint)(*A_0);
			uint num3 = (uint)((*(A_0 + 8) - (int)num2) / 24 * 24);
			void* ptr3 = num2;
			if (num3 >= 4096U)
			{
				<Module>.std._Adjust_manually_vector_aligned(ref ptr3, ref num3);
			}
			<Module>.delete(ptr3, num3);
			*A_0 = 0;
			*(A_0 + 4) = 0;
			*(A_0 + 8) = 0;
		}
		<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Buy_raw(A_0, num);
	}

	// Token: 0x0600008E RID: 142 RVA: 0x00004E38 File Offset: 0x00004238
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std._Copy_unchecked<class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*,class\u0020std::basic_string<char,struct\u0020std::char_traits<char>,class\u0020std::allocator<char>\u0020>\u0020*>(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _First, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Last, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Dest)
	{
		if (_First != _Last)
		{
			do
			{
				if (_Dest != _First)
				{
					integral_constant<bool,0> integral_constant<bool,0>;
					initblk(ref integral_constant<bool,0>, 0, 1);
					<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Copy_assign(_Dest, _First, integral_constant<bool,0>);
				}
				_Dest += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
				_First += 24 / sizeof(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>);
			}
			while (_First != _Last);
		}
		return _Dest;
	}

	// Token: 0x0600008F RID: 143 RVA: 0x00004A14 File Offset: 0x00003E14
	internal unsafe static void std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>._Copy_assign(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* _Right, integral_constant<bool,0> __unnamed001)
	{
		uint num = (uint)(*(_Right + 16));
		sbyte* ptr = _Right;
		if (((16 <= *(_Right + 20)) ? 1 : 0) != 0)
		{
			ptr = *_Right;
		}
		<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.assign(A_0, ptr, num);
	}

	// Token: 0x06000090 RID: 144 RVA: 0x00004ABC File Offset: 0x00003EBC
	internal unsafe static basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.{ctor}(basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* A_0, sbyte* _Ptr, uint _Count)
	{
		*A_0 = 0;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr;
		basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>* ptr2;
		try
		{
			ptr = A_0 + 16;
			*ptr = 0;
			ptr2 = A_0 + 20;
			*ptr2 = 0;
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._String_val<std::_Simple_types<char>\u0020>._Bxty.{dtor}), A_0);
			throw;
		}
		try
		{
			*ptr = 0;
			*ptr2 = 15;
			*A_0 = 0;
			<Module>.std.basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>.assign(A_0, _Ptr, _Count);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(std._Compressed_pair<std::allocator<char>,std::_String_val<std::_Simple_types<char>\u0020>,1>.{dtor}), A_0);
			throw;
		}
		return A_0;
	}

	// Token: 0x06000091 RID: 145 RVA: 0x00005D0C File Offset: 0x0000510C
	internal unsafe static void msclr.interop.details.char_buffer<char>.{dtor}(char_buffer<char>* A_0)
	{
		<Module>.delete[](*A_0);
	}

	// Token: 0x06000092 RID: 146 RVA: 0x00006D4C File Offset: 0x0000614C
	[SecurityCritical]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[HandleProcessCorruptedStateExceptions]
	[SecurityPermission(SecurityAction.Assert, UnmanagedCode = true)]
	internal unsafe static void ___CxxCallUnwindDtor(delegate*<void*, void> pDtor, void* pThis)
	{
		try
		{
			calli(System.Void(System.Void*), pThis, pDtor);
		}
		catch when (endfilter(<Module>.__FrameUnwindFilter(Marshal.GetExceptionPointers()) != null))
		{
		}
	}

	// Token: 0x06000093 RID: 147 RVA: 0x00006E1C File Offset: 0x0000621C
	[HandleProcessCorruptedStateExceptions]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[SecurityCritical]
	internal unsafe static void __ehvec_dtor(void* ptr, uint size, uint count, delegate*<void*, void> destructor)
	{
		bool flag = false;
		ptr = (void*)(size * count + (byte*)ptr);
		try
		{
			for (;;)
			{
				int num = (int)count;
				count -= 1U;
				if (num == 0)
				{
					break;
				}
				ptr = (void*)((byte*)ptr - size);
				calli(System.Void(System.Void*), ptr, destructor);
			}
			flag = true;
		}
		finally
		{
			if (!flag)
			{
				<Module>.__ArrayUnwind(ptr, size, count, destructor);
			}
		}
	}

	// Token: 0x06000094 RID: 148 RVA: 0x00006D90 File Offset: 0x00006190
	[SecurityCritical]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[SecurityPermission(SecurityAction.Assert, UnmanagedCode = true)]
	internal unsafe static int ?A0x7995cc7c.ArrayUnwindFilter(_EXCEPTION_POINTERS* pExPtrs)
	{
		EHExceptionRecord* ptr = *(int*)pExPtrs;
		if (*(int*)ptr != -529697949)
		{
			return 0;
		}
		*<Module>.__current_exception() = ptr;
		int num = *(int*)(pExPtrs + 4 / sizeof(_EXCEPTION_POINTERS));
		*<Module>.__current_exception_context() = num;
		<Module>.terminate();
		return 0;
	}

	// Token: 0x06000095 RID: 149 RVA: 0x00006DC4 File Offset: 0x000061C4
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[HandleProcessCorruptedStateExceptions]
	[SecurityCritical]
	internal unsafe static void __ArrayUnwind(void* ptr, uint size, uint count, delegate*<void*, void> destructor)
	{
		try
		{
			for (uint num = 0U; num != count; num += 1U)
			{
				ptr = (void*)((byte*)ptr - size);
				calli(System.Void(System.Void*), ptr, destructor);
			}
		}
		catch when (endfilter(<Module>.?A0x7995cc7c.ArrayUnwindFilter(Marshal.GetExceptionPointers()) != null))
		{
		}
	}

	// Token: 0x06000096 RID: 150 RVA: 0x00007604 File Offset: 0x00006A04
	internal static void <CrtImplementationDetails>.ThrowNestedModuleLoadException(Exception innerException, Exception nestedException)
	{
		throw new ModuleLoadExceptionHandlerException("A nested exception occurred after the primary exception that caused the C++ module to fail to load.\n", innerException, nestedException);
	}

	// Token: 0x06000097 RID: 151 RVA: 0x00006FFC File Offset: 0x000063FC
	internal static void <CrtImplementationDetails>.ThrowModuleLoadException(string errorMessage)
	{
		throw new ModuleLoadException(errorMessage);
	}

	// Token: 0x06000098 RID: 152 RVA: 0x00007010 File Offset: 0x00006410
	internal static void <CrtImplementationDetails>.ThrowModuleLoadException(string errorMessage, Exception innerException)
	{
		throw new ModuleLoadException(errorMessage, innerException);
	}

	// Token: 0x06000099 RID: 153 RVA: 0x0000712C File Offset: 0x0000652C
	internal static void <CrtImplementationDetails>.RegisterModuleUninitializer(EventHandler handler)
	{
		ModuleUninitializer._ModuleUninitializer.AddHandler(handler);
	}

	// Token: 0x0600009A RID: 154 RVA: 0x00007144 File Offset: 0x00006544
	[SecuritySafeCritical]
	internal unsafe static Guid <CrtImplementationDetails>.FromGUID(_GUID* guid)
	{
		Guid guid2 = new Guid((uint)(*guid), *(guid + 4), *(guid + 6), *(guid + 8), *(guid + 9), *(guid + 10), *(guid + 11), *(guid + 12), *(guid + 13), *(guid + 14), *(guid + 15));
		return guid2;
	}

	// Token: 0x0600009B RID: 155 RVA: 0x0000718C File Offset: 0x0000658C
	[SecurityCritical]
	internal unsafe static int __get_default_appdomain(IUnknown** ppUnk)
	{
		ICorRuntimeHost* ptr = null;
		int num;
		try
		{
			Guid guid = <Module>.<CrtImplementationDetails>.FromGUID(ref <Module>._GUID_cb2f6722_ab3a_11d2_9c40_00c04fa30a3e);
			ptr = (ICorRuntimeHost*)RuntimeEnvironment.GetRuntimeInterfaceAsIntPtr(<Module>.<CrtImplementationDetails>.FromGUID(ref <Module>._GUID_cb2f6723_ab3a_11d2_9c40_00c04fa30a3e), guid).ToPointer();
			goto IL_0035;
		}
		catch (Exception ex)
		{
			num = Marshal.GetHRForException(ex);
		}
		if (num < 0)
		{
			return num;
		}
		IL_0035:
		int num2 = *(*(int*)ptr + 52);
		num = calli(System.Int32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall)(System.IntPtr,IUnknown**), ptr, ppUnk, (IntPtr)num2);
		ICorRuntimeHost* ptr2 = ptr;
		uint num3 = calli(System.UInt32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall)(System.IntPtr), ptr2, (IntPtr)(*(*(int*)ptr2 + 8)));
		return num;
	}

	// Token: 0x0600009C RID: 156 RVA: 0x00007208 File Offset: 0x00006608
	internal unsafe static void __release_appdomain(IUnknown* ppUnk)
	{
		uint num = calli(System.UInt32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall)(System.IntPtr), ppUnk, (IntPtr)(*(*(int*)ppUnk + 8)));
	}

	// Token: 0x0600009D RID: 157 RVA: 0x00007224 File Offset: 0x00006624
	[SecurityCritical]
	internal unsafe static AppDomain <CrtImplementationDetails>.GetDefaultDomain()
	{
		IUnknown* ptr = null;
		int num = <Module>.__get_default_appdomain(&ptr);
		if (num >= 0)
		{
			try
			{
				IntPtr intPtr = new IntPtr((void*)ptr);
				return (AppDomain)Marshal.GetObjectForIUnknown(intPtr);
			}
			finally
			{
				<Module>.__release_appdomain(ptr);
			}
		}
		Marshal.ThrowExceptionForHR(num);
		return null;
	}

	// Token: 0x0600009E RID: 158 RVA: 0x00007284 File Offset: 0x00006684
	[SecurityCritical]
	internal unsafe static void <CrtImplementationDetails>.DoCallBackInDefaultDomain(delegate* unmanaged[Stdcall, Stdcall]<void*, int> function, void* cookie)
	{
		Guid guid = <Module>.<CrtImplementationDetails>.FromGUID(ref <Module>._GUID_90f1a06c_7712_4762_86b5_7a5eba6bdb02);
		ICLRRuntimeHost* ptr = (ICLRRuntimeHost*)RuntimeEnvironment.GetRuntimeInterfaceAsIntPtr(<Module>.<CrtImplementationDetails>.FromGUID(ref <Module>._GUID_90f1a06e_7712_4762_86b5_7a5eba6bdb02), guid).ToPointer();
		try
		{
			AppDomain appDomain = <Module>.<CrtImplementationDetails>.GetDefaultDomain();
			int num = *(*(int*)ptr + 32);
			uint id = (uint)appDomain.Id;
			int num2 = calli(System.Int32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall)(System.IntPtr,System.UInt32 modopt(System.Runtime.CompilerServices.IsLong),System.Int32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall) (System.Void*),System.Void*), ptr, id, function, cookie, (IntPtr)num);
			if (num2 < 0)
			{
				Marshal.ThrowExceptionForHR(num2);
			}
		}
		finally
		{
			ICLRRuntimeHost* ptr2 = ptr;
			uint num3 = calli(System.UInt32 modopt(System.Runtime.CompilerServices.IsLong) modopt(System.Runtime.CompilerServices.CallConvStdcall)(System.IntPtr), ptr2, (IntPtr)(*(*(int*)ptr2 + 8)));
		}
	}

	// Token: 0x0600009F RID: 159 RVA: 0x0000730C File Offset: 0x0000670C
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool __scrt_is_safe_for_managed_code()
	{
		uint _scrt_native_dllmain_reason = <Module>.__scrt_native_dllmain_reason;
		if (_scrt_native_dllmain_reason != 0U && _scrt_native_dllmain_reason != 1U)
		{
			return 1;
		}
		return 0;
	}

	// Token: 0x060000A0 RID: 160 RVA: 0x0000733C File Offset: 0x0000673C
	[SecuritySafeCritical]
	internal unsafe static int <CrtImplementationDetails>.DefaultDomain.DoNothing(void* cookie)
	{
		GC.KeepAlive(int.MaxValue);
		return 0;
	}

	// Token: 0x060000A1 RID: 161 RVA: 0x0000735C File Offset: 0x0000675C
	[SecuritySafeCritical]
	[return: MarshalAs(UnmanagedType.U1)]
	internal unsafe static bool <CrtImplementationDetails>.DefaultDomain.HasPerProcess()
	{
		if (<Module>.?hasPerProcess@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A == (TriBool)2)
		{
			void** ptr = (void**)(&<Module>.__xc_mp_a);
			if ((ref <Module>.__xc_mp_a) < (ref <Module>.__xc_mp_z))
			{
				while (*(int*)ptr == 0)
				{
					ptr += 4 / sizeof(void*);
					if (ptr >= (void**)(&<Module>.__xc_mp_z))
					{
						goto IL_0034;
					}
				}
				<Module>.?hasPerProcess@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A = (TriBool)(-1);
				return 1;
			}
			IL_0034:
			<Module>.?hasPerProcess@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A = (TriBool)0;
			return 0;
		}
		return (<Module>.?hasPerProcess@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A == (TriBool)(-1)) ? 1 : 0;
	}

	// Token: 0x060000A2 RID: 162 RVA: 0x000073B0 File Offset: 0x000067B0
	[SecuritySafeCritical]
	[return: MarshalAs(UnmanagedType.U1)]
	internal unsafe static bool <CrtImplementationDetails>.DefaultDomain.HasNative()
	{
		if (<Module>.?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A == (TriBool)2)
		{
			void** ptr = (void**)(&<Module>.__xi_a);
			if ((ref <Module>.__xi_a) < (ref <Module>.__xi_z))
			{
				while (*(int*)ptr == 0)
				{
					ptr += 4 / sizeof(void*);
					if (ptr >= (void**)(&<Module>.__xi_z))
					{
						goto IL_0034;
					}
				}
				<Module>.?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A = (TriBool)(-1);
				return 1;
			}
			IL_0034:
			void** ptr2 = (void**)(&<Module>.__xc_a);
			if ((ref <Module>.__xc_a) < (ref <Module>.__xc_z))
			{
				while (*(int*)ptr2 == 0)
				{
					ptr2 += 4 / sizeof(void*);
					if (ptr2 >= (void**)(&<Module>.__xc_z))
					{
						goto IL_0060;
					}
				}
				<Module>.?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A = (TriBool)(-1);
				return 1;
			}
			IL_0060:
			<Module>.?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A = (TriBool)0;
			return 0;
		}
		return (<Module>.?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A == (TriBool)(-1)) ? 1 : 0;
	}

	// Token: 0x060000A3 RID: 163 RVA: 0x00007430 File Offset: 0x00006830
	[SecuritySafeCritical]
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool <CrtImplementationDetails>.DefaultDomain.NeedsInitialization()
	{
		int num;
		if ((<Module>.<CrtImplementationDetails>.DefaultDomain.HasPerProcess() != null && !<Module>.?InitializedPerProcess@DefaultDomain@<CrtImplementationDetails>@@2_NA) || (<Module>.<CrtImplementationDetails>.DefaultDomain.HasNative() != null && !<Module>.?InitializedNative@DefaultDomain@<CrtImplementationDetails>@@2_NA && <Module>.__scrt_current_native_startup_state == (__scrt_native_startup_state)0))
		{
			num = 1;
		}
		else
		{
			num = 0;
		}
		return (byte)num;
	}

	// Token: 0x060000A4 RID: 164 RVA: 0x00007468 File Offset: 0x00006868
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool <CrtImplementationDetails>.DefaultDomain.NeedsUninitialization()
	{
		return <Module>.?Entered@DefaultDomain@<CrtImplementationDetails>@@2_NA;
	}

	// Token: 0x060000A5 RID: 165 RVA: 0x0000747C File Offset: 0x0000687C
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.DefaultDomain.Initialize()
	{
		<Module>.<CrtImplementationDetails>.DoCallBackInDefaultDomain(<Module>.__unep@?DoNothing@DefaultDomain@<CrtImplementationDetails>@@$$FCGJPAX@Z, null);
	}

	// Token: 0x060000A6 RID: 166 RVA: 0x00001068 File Offset: 0x00000468
	internal static void ?A0xcb795ccb.??__E?Initialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA@@YMXXZ()
	{
		<Module>.?Initialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA = 0;
	}

	// Token: 0x060000A7 RID: 167 RVA: 0x0000107C File Offset: 0x0000047C
	internal static void ?A0xcb795ccb.??__E?Uninitialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA@@YMXXZ()
	{
		<Module>.?Uninitialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA = 0;
	}

	// Token: 0x060000A8 RID: 168 RVA: 0x00001090 File Offset: 0x00000490
	internal static void ?A0xcb795ccb.??__E?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA@@YMXXZ()
	{
		<Module>.?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA = false;
	}

	// Token: 0x060000A9 RID: 169 RVA: 0x000010A4 File Offset: 0x000004A4
	internal static void ?A0xcb795ccb.??__E?InitializedVtables@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A@@YMXXZ()
	{
		<Module>.?InitializedVtables@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)0;
	}

	// Token: 0x060000AA RID: 170 RVA: 0x000010B8 File Offset: 0x000004B8
	internal static void ?A0xcb795ccb.??__E?InitializedNative@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A@@YMXXZ()
	{
		<Module>.?InitializedNative@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)0;
	}

	// Token: 0x060000AB RID: 171 RVA: 0x000010CC File Offset: 0x000004CC
	internal static void ?A0xcb795ccb.??__E?InitializedPerProcess@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A@@YMXXZ()
	{
		<Module>.?InitializedPerProcess@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)0;
	}

	// Token: 0x060000AC RID: 172 RVA: 0x000010E0 File Offset: 0x000004E0
	internal static void ?A0xcb795ccb.??__E?InitializedPerAppDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A@@YMXXZ()
	{
		<Module>.?InitializedPerAppDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)0;
	}

	// Token: 0x060000AD RID: 173 RVA: 0x00007658 File Offset: 0x00006A58
	[DebuggerStepThrough]
	[SecuritySafeCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializeVtables(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load during vtable initialization.\n");
		<Module>.?InitializedVtables@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)1;
		<Module>._initterm_m((delegate*<void*>*)(&<Module>.__xi_vt_a), (delegate*<void*>*)(&<Module>.__xi_vt_z));
		<Module>.?InitializedVtables@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)2;
	}

	// Token: 0x060000AE RID: 174 RVA: 0x0000768C File Offset: 0x00006A8C
	[SecuritySafeCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializeDefaultAppDomain(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load while attempting to initialize the default appdomain.\n");
		<Module>.<CrtImplementationDetails>.DefaultDomain.Initialize();
	}

	// Token: 0x060000AF RID: 175 RVA: 0x000076AC File Offset: 0x00006AAC
	[DebuggerStepThrough]
	[SecuritySafeCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializeNative(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load during native initialization.\n");
		<Module>.__security_init_cookie();
		<Module>.?InitializedNative@DefaultDomain@<CrtImplementationDetails>@@2_NA = true;
		if (<Module>.__scrt_is_safe_for_managed_code() == null)
		{
			<Module>.abort();
		}
		if (<Module>.__scrt_current_native_startup_state == (__scrt_native_startup_state)1)
		{
			<Module>.abort();
		}
		if (<Module>.__scrt_current_native_startup_state == (__scrt_native_startup_state)0)
		{
			<Module>.?InitializedNative@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)1;
			<Module>.__scrt_current_native_startup_state = (__scrt_native_startup_state)1;
			if (<Module>._initterm_e((delegate* unmanaged[Cdecl, Cdecl]<int>*)(&<Module>.__xi_a), (delegate* unmanaged[Cdecl, Cdecl]<int>*)(&<Module>.__xi_z)) != 0)
			{
				<Module>.<CrtImplementationDetails>.ThrowModuleLoadException(<Module>.gcroot<System::String\u0020^>..P$AAVString@System@@(A_0));
			}
			<Module>._initterm((delegate* unmanaged[Cdecl, Cdecl]<void>*)(&<Module>.__xc_a), (delegate* unmanaged[Cdecl, Cdecl]<void>*)(&<Module>.__xc_z));
			<Module>.__scrt_current_native_startup_state = (__scrt_native_startup_state)2;
			<Module>.?InitializedNativeFromCCTOR@DefaultDomain@<CrtImplementationDetails>@@2_NA = true;
			<Module>.?InitializedNative@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)2;
		}
	}

	// Token: 0x060000B0 RID: 176 RVA: 0x0000773C File Offset: 0x00006B3C
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializePerProcess(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load during process initialization.\n");
		<Module>.?InitializedPerProcess@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)1;
		<Module>._initatexit_m();
		<Module>._initterm_m((delegate*<void*>*)(&<Module>.__xc_mp_a), (delegate*<void*>*)(&<Module>.__xc_mp_z));
		<Module>.?InitializedPerProcess@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)2;
		<Module>.?InitializedPerProcess@DefaultDomain@<CrtImplementationDetails>@@2_NA = true;
	}

	// Token: 0x060000B1 RID: 177 RVA: 0x0000777C File Offset: 0x00006B7C
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializePerAppDomain(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load during appdomain initialization.\n");
		<Module>.?InitializedPerAppDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)1;
		<Module>._initatexit_app_domain();
		<Module>._initterm_m((delegate*<void*>*)(&<Module>.__xc_ma_a), (delegate*<void*>*)(&<Module>.__xc_ma_z));
		<Module>.?InitializedPerAppDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A = (Progress)2;
	}

	// Token: 0x060000B2 RID: 178 RVA: 0x000077B8 File Offset: 0x00006BB8
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.InitializeUninitializer(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load during registration for the unload events.\n");
		<Module>.<CrtImplementationDetails>.RegisterModuleUninitializer(new EventHandler(<Module>.<CrtImplementationDetails>.LanguageSupport.DomainUnload));
	}

	// Token: 0x060000B3 RID: 179 RVA: 0x000077E4 File Offset: 0x00006BE4
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport._Initialize(LanguageSupport* A_0)
	{
		<Module>.?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA = AppDomain.CurrentDomain.IsDefaultAppDomain();
		if (<Module>.?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA)
		{
			<Module>.?Entered@DefaultDomain@<CrtImplementationDetails>@@2_NA = true;
		}
		void* ptr = <Module>._getFiberPtrId();
		int num = 0;
		int num2 = 0;
		int num3 = 0;
		RuntimeHelpers.PrepareConstrainedRegions();
		try
		{
			while (num2 == 0)
			{
				try
				{
				}
				finally
				{
					IntPtr intPtr = (IntPtr)0;
					IntPtr intPtr2 = (IntPtr)ptr;
					IntPtr intPtr3 = Interlocked.CompareExchange(ref <Module>.__scrt_native_startup_lock, intPtr2, intPtr);
					void* ptr2 = (void*)intPtr3;
					if (ptr2 == null)
					{
						num2 = 1;
					}
					else if (ptr2 == ptr)
					{
						num = 1;
						num2 = 1;
					}
				}
				if (num2 == 0)
				{
					<Module>.Sleep(1000);
				}
			}
			<Module>.<CrtImplementationDetails>.LanguageSupport.InitializeVtables(A_0);
			if (<Module>.?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA)
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport.InitializeNative(A_0);
				<Module>.<CrtImplementationDetails>.LanguageSupport.InitializePerProcess(A_0);
			}
			else if (<Module>.<CrtImplementationDetails>.DefaultDomain.NeedsInitialization() != null)
			{
				num3 = 1;
			}
		}
		finally
		{
			if (num == 0)
			{
				IntPtr intPtr4 = (IntPtr)0;
				Interlocked.Exchange(ref <Module>.__scrt_native_startup_lock, intPtr4);
			}
		}
		if (num3 != 0)
		{
			<Module>.<CrtImplementationDetails>.LanguageSupport.InitializeDefaultAppDomain(A_0);
		}
		<Module>.<CrtImplementationDetails>.LanguageSupport.InitializePerAppDomain(A_0);
		<Module>.?Initialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA = 1;
		<Module>.<CrtImplementationDetails>.LanguageSupport.InitializeUninitializer(A_0);
	}

	// Token: 0x060000B4 RID: 180 RVA: 0x00007494 File Offset: 0x00006894
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.LanguageSupport.UninitializeAppDomain()
	{
		<Module>._app_exit_callback();
	}

	// Token: 0x060000B5 RID: 181 RVA: 0x000074A8 File Offset: 0x000068A8
	[SecurityCritical]
	internal unsafe static int <CrtImplementationDetails>.LanguageSupport._UninitializeDefaultDomain(void* cookie)
	{
		<Module>._exit_callback();
		<Module>.?InitializedPerProcess@DefaultDomain@<CrtImplementationDetails>@@2_NA = false;
		if (<Module>.?InitializedNativeFromCCTOR@DefaultDomain@<CrtImplementationDetails>@@2_NA)
		{
			<Module>._cexit();
			<Module>.__scrt_current_native_startup_state = (__scrt_native_startup_state)0;
			<Module>.?InitializedNativeFromCCTOR@DefaultDomain@<CrtImplementationDetails>@@2_NA = false;
		}
		<Module>.?InitializedNative@DefaultDomain@<CrtImplementationDetails>@@2_NA = false;
		return 0;
	}

	// Token: 0x060000B6 RID: 182 RVA: 0x000074E0 File Offset: 0x000068E0
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.LanguageSupport.UninitializeDefaultDomain()
	{
		if (<Module>.<CrtImplementationDetails>.DefaultDomain.NeedsUninitialization() != null)
		{
			if (AppDomain.CurrentDomain.IsDefaultAppDomain())
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport._UninitializeDefaultDomain(null);
			}
			else
			{
				<Module>.<CrtImplementationDetails>.DoCallBackInDefaultDomain(<Module>.__unep@?_UninitializeDefaultDomain@LanguageSupport@<CrtImplementationDetails>@@$$FCGJPAX@Z, null);
			}
		}
	}

	// Token: 0x060000B7 RID: 183 RVA: 0x00007514 File Offset: 0x00006914
	[SecurityCritical]
	[PrePrepareMethod]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	internal static void <CrtImplementationDetails>.LanguageSupport.DomainUnload(object A_0, EventArgs A_1)
	{
		if (<Module>.?Initialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA != 0 && Interlocked.Exchange(ref <Module>.?Uninitialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA, 1) == 0)
		{
			byte b = ((Interlocked.Decrement(ref <Module>.?Count@AllDomains@<CrtImplementationDetails>@@2HA) == 0) ? 1 : 0);
			<Module>.<CrtImplementationDetails>.LanguageSupport.UninitializeAppDomain();
			if (b != 0)
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport.UninitializeDefaultDomain();
			}
		}
	}

	// Token: 0x060000B8 RID: 184 RVA: 0x00007908 File Offset: 0x00006D08
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.Cleanup(LanguageSupport* A_0, Exception innerException)
	{
		try
		{
			bool flag = ((Interlocked.Decrement(ref <Module>.?Count@AllDomains@<CrtImplementationDetails>@@2HA) == 0) ? 1 : 0) != 0;
			<Module>.<CrtImplementationDetails>.LanguageSupport.UninitializeAppDomain();
			if (flag)
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport.UninitializeDefaultDomain();
			}
		}
		catch (Exception ex)
		{
			<Module>.<CrtImplementationDetails>.ThrowNestedModuleLoadException(innerException, ex);
		}
		catch (object obj)
		{
			<Module>.<CrtImplementationDetails>.ThrowNestedModuleLoadException(innerException, null);
		}
	}

	// Token: 0x060000B9 RID: 185 RVA: 0x0000797C File Offset: 0x00006D7C
	[SecurityCritical]
	internal unsafe static LanguageSupport* <CrtImplementationDetails>.LanguageSupport.{ctor}(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.{ctor}(A_0);
		return A_0;
	}

	// Token: 0x060000BA RID: 186 RVA: 0x00007994 File Offset: 0x00006D94
	[SecurityCritical]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.{dtor}(LanguageSupport* A_0)
	{
		<Module>.gcroot<System::String\u0020^>.{dtor}(A_0);
	}

	// Token: 0x060000BB RID: 187 RVA: 0x000079A8 File Offset: 0x00006DA8
	[SecurityCritical]
	[DebuggerStepThrough]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	internal unsafe static void <CrtImplementationDetails>.LanguageSupport.Initialize(LanguageSupport* A_0)
	{
		bool flag = false;
		RuntimeHelpers.PrepareConstrainedRegions();
		try
		{
			<Module>.gcroot<System::String\u0020^>.=(A_0, "The C++ module failed to load.\n");
			RuntimeHelpers.PrepareConstrainedRegions();
			try
			{
			}
			finally
			{
				Interlocked.Increment(ref <Module>.?Count@AllDomains@<CrtImplementationDetails>@@2HA);
				flag = true;
			}
			<Module>.<CrtImplementationDetails>.LanguageSupport._Initialize(A_0);
		}
		catch (Exception ex)
		{
			if (flag)
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport.Cleanup(A_0, ex);
			}
			<Module>.<CrtImplementationDetails>.ThrowModuleLoadException(<Module>.gcroot<System::String\u0020^>..P$AAVString@System@@(A_0), ex);
		}
		catch (object obj)
		{
			if (flag)
			{
				<Module>.<CrtImplementationDetails>.LanguageSupport.Cleanup(A_0, null);
			}
			<Module>.<CrtImplementationDetails>.ThrowModuleLoadException(<Module>.gcroot<System::String\u0020^>..P$AAVString@System@@(A_0), null);
		}
	}

	// Token: 0x060000BC RID: 188 RVA: 0x00007A64 File Offset: 0x00006E64
	[SecurityCritical]
	[DebuggerStepThrough]
	static unsafe <Module>()
	{
		LanguageSupport languageSupport;
		<Module>.<CrtImplementationDetails>.LanguageSupport.{ctor}(ref languageSupport);
		try
		{
			<Module>.<CrtImplementationDetails>.LanguageSupport.Initialize(ref languageSupport);
		}
		catch
		{
			<Module>.___CxxCallUnwindDtor(ldftn(<CrtImplementationDetails>.LanguageSupport.{dtor}), (void*)(&languageSupport));
			throw;
		}
		<Module>.<CrtImplementationDetails>.LanguageSupport.{dtor}(ref languageSupport);
	}

	// Token: 0x060000BD RID: 189 RVA: 0x00007550 File Offset: 0x00006950
	[SecuritySafeCritical]
	internal unsafe static string gcroot<System::String\u0020^>..P$AAVString@System@@(gcroot<System::String\u0020^>* A_0)
	{
		IntPtr intPtr = new IntPtr(*A_0);
		return ((GCHandle)intPtr).Target;
	}

	// Token: 0x060000BE RID: 190 RVA: 0x00007574 File Offset: 0x00006974
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static gcroot<System::String\u0020^>* gcroot<System::String\u0020^>.=(gcroot<System::String\u0020^>* A_0, string t)
	{
		IntPtr intPtr = new IntPtr(*A_0);
		((GCHandle)intPtr).Target = t;
		return A_0;
	}

	// Token: 0x060000BF RID: 191 RVA: 0x0000759C File Offset: 0x0000699C
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static void gcroot<System::String\u0020^>.{dtor}(gcroot<System::String\u0020^>* A_0)
	{
		IntPtr intPtr = new IntPtr(*A_0);
		((GCHandle)intPtr).Free();
		*A_0 = 0;
	}

	// Token: 0x060000C0 RID: 192 RVA: 0x000075C4 File Offset: 0x000069C4
	[SecuritySafeCritical]
	[DebuggerStepThrough]
	internal unsafe static gcroot<System::String\u0020^>* gcroot<System::String\u0020^>.{ctor}(gcroot<System::String\u0020^>* A_0)
	{
		*A_0 = ((IntPtr)GCHandle.Alloc(null)).ToPointer();
		return A_0;
	}

	// Token: 0x060000C1 RID: 193 RVA: 0x00007AE4 File Offset: 0x00006EE4
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static void _Init_thread_header_m(int* pOnce)
	{
		if (*(int*)pOnce >= -1)
		{
			<Module>._Init_thread_lock();
			if (*(int*)pOnce == 0)
			{
				*(int*)pOnce = -1;
			}
			else if (*(int*)pOnce == -1)
			{
				do
				{
					<Module>._Init_thread_wait(100);
					if (*(int*)pOnce == 0)
					{
						goto IL_0036;
					}
				}
				while (*(int*)pOnce == -1);
				goto IL_0042;
				IL_0036:
				*(int*)pOnce = -1;
				<Module>._Init_thread_unlock();
				return;
			}
			IL_0042:
			<Module>._Init_thread_unlock();
		}
	}

	// Token: 0x060000C2 RID: 194 RVA: 0x00007B38 File Offset: 0x00006F38
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void _Init_thread_abort_m(int* pOnce)
	{
		<Module>._Init_thread_lock();
		*(int*)pOnce = 0;
		<Module>._Init_thread_notify();
		<Module>._Init_thread_unlock();
	}

	// Token: 0x060000C3 RID: 195 RVA: 0x00007B5C File Offset: 0x00006F5C
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void _Init_thread_footer_m(int* pOnce)
	{
		<Module>._Init_thread_lock();
		<Module>._Init_global_epoch++;
		*(int*)pOnce = <Module>._Init_global_epoch;
		<Module>._Init_thread_notify();
		<Module>._Init_thread_unlock();
	}

	// Token: 0x060000C4 RID: 196 RVA: 0x00007B90 File Offset: 0x00006F90
	[SecurityCritical]
	[DebuggerStepThrough]
	internal static ValueType <CrtImplementationDetails>.AtExitLock._handle()
	{
		if (<Module>.?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA != null)
		{
			IntPtr intPtr = new IntPtr(<Module>.?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA);
			return GCHandle.FromIntPtr(intPtr);
		}
		return null;
	}

	// Token: 0x060000C5 RID: 197 RVA: 0x00008044 File Offset: 0x00007444
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.AtExitLock._lock_Construct(object value)
	{
		<Module>.?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA = null;
		<Module>.<CrtImplementationDetails>.AtExitLock._lock_Set(value);
	}

	// Token: 0x060000C6 RID: 198 RVA: 0x00007BC0 File Offset: 0x00006FC0
	[SecurityCritical]
	[DebuggerStepThrough]
	internal static void <CrtImplementationDetails>.AtExitLock._lock_Set(object value)
	{
		ValueType valueType = <Module>.<CrtImplementationDetails>.AtExitLock._handle();
		if (valueType == null)
		{
			valueType = GCHandle.Alloc(value);
			<Module>.?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA = GCHandle.ToIntPtr((GCHandle)valueType).ToPointer();
		}
		else
		{
			((GCHandle)valueType).Target = value;
		}
	}

	// Token: 0x060000C7 RID: 199 RVA: 0x00007C10 File Offset: 0x00007010
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static object <CrtImplementationDetails>.AtExitLock._lock_Get()
	{
		ValueType valueType = <Module>.<CrtImplementationDetails>.AtExitLock._handle();
		if (valueType != null)
		{
			return ((GCHandle)valueType).Target;
		}
		return null;
	}

	// Token: 0x060000C8 RID: 200 RVA: 0x00007C34 File Offset: 0x00007034
	[SecurityCritical]
	[DebuggerStepThrough]
	internal static void <CrtImplementationDetails>.AtExitLock._lock_Destruct()
	{
		ValueType valueType = <Module>.<CrtImplementationDetails>.AtExitLock._handle();
		if (valueType != null)
		{
			((GCHandle)valueType).Free();
			<Module>.?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA = null;
		}
	}

	// Token: 0x060000C9 RID: 201 RVA: 0x00007C5C File Offset: 0x0000705C
	[DebuggerStepThrough]
	[SecurityCritical]
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool <CrtImplementationDetails>.AtExitLock.IsInitialized()
	{
		return (<Module>.<CrtImplementationDetails>.AtExitLock._lock_Get() != null) ? 1 : 0;
	}

	// Token: 0x060000CA RID: 202 RVA: 0x00008060 File Offset: 0x00007460
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.AtExitLock.AddRef()
	{
		if (<Module>.<CrtImplementationDetails>.AtExitLock.IsInitialized() == null)
		{
			<Module>.<CrtImplementationDetails>.AtExitLock._lock_Construct(new object());
			<Module>.?_ref_count@AtExitLock@<CrtImplementationDetails>@@$$Q0HA = 0;
		}
		<Module>.?_ref_count@AtExitLock@<CrtImplementationDetails>@@$$Q0HA++;
	}

	// Token: 0x060000CB RID: 203 RVA: 0x00007C78 File Offset: 0x00007078
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.AtExitLock.RemoveRef()
	{
		<Module>.?_ref_count@AtExitLock@<CrtImplementationDetails>@@$$Q0HA--;
		if (<Module>.?_ref_count@AtExitLock@<CrtImplementationDetails>@@$$Q0HA == 0)
		{
			<Module>.<CrtImplementationDetails>.AtExitLock._lock_Destruct();
		}
	}

	// Token: 0x060000CC RID: 204 RVA: 0x00007CA0 File Offset: 0x000070A0
	[SecurityCritical]
	[DebuggerStepThrough]
	internal static void <CrtImplementationDetails>.AtExitLock.Enter()
	{
		Monitor.Enter(<Module>.<CrtImplementationDetails>.AtExitLock._lock_Get());
	}

	// Token: 0x060000CD RID: 205 RVA: 0x00007CB8 File Offset: 0x000070B8
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static void <CrtImplementationDetails>.AtExitLock.Exit()
	{
		Monitor.Exit(<Module>.<CrtImplementationDetails>.AtExitLock._lock_Get());
	}

	// Token: 0x060000CE RID: 206 RVA: 0x00007CD0 File Offset: 0x000070D0
	[SecurityCritical]
	[DebuggerStepThrough]
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool ?A0xff04d0ec.__global_lock()
	{
		bool flag = false;
		if (<Module>.<CrtImplementationDetails>.AtExitLock.IsInitialized() != null)
		{
			<Module>.<CrtImplementationDetails>.AtExitLock.Enter();
			flag = true;
		}
		return flag;
	}

	// Token: 0x060000CF RID: 207 RVA: 0x00007CF0 File Offset: 0x000070F0
	[SecurityCritical]
	[DebuggerStepThrough]
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool ?A0xff04d0ec.__global_unlock()
	{
		bool flag = false;
		if (<Module>.<CrtImplementationDetails>.AtExitLock.IsInitialized() != null)
		{
			<Module>.<CrtImplementationDetails>.AtExitLock.Exit();
			flag = true;
		}
		return flag;
	}

	// Token: 0x060000D0 RID: 208 RVA: 0x00008090 File Offset: 0x00007490
	[SecurityCritical]
	[DebuggerStepThrough]
	[return: MarshalAs(UnmanagedType.U1)]
	internal static bool ?A0xff04d0ec.__alloc_global_lock()
	{
		<Module>.<CrtImplementationDetails>.AtExitLock.AddRef();
		return <Module>.<CrtImplementationDetails>.AtExitLock.IsInitialized();
	}

	// Token: 0x060000D1 RID: 209 RVA: 0x00007D10 File Offset: 0x00007110
	[DebuggerStepThrough]
	[SecurityCritical]
	internal static void ?A0xff04d0ec.__dealloc_global_lock()
	{
		<Module>.<CrtImplementationDetails>.AtExitLock.RemoveRef();
	}

	// Token: 0x060000D2 RID: 210 RVA: 0x00007D24 File Offset: 0x00007124
	[SecurityCritical]
	internal unsafe static int _atexit_helper(delegate*<void> func, uint* __pexit_list_size, delegate*<void>** __ponexitend_e, delegate*<void>** __ponexitbegin_e)
	{
		delegate*<void> system.Void_u0020() = 0;
		if (func == null)
		{
			return -1;
		}
		if (<Module>.?A0xff04d0ec.__global_lock() == 1)
		{
			try
			{
				delegate*<void>* ptr = (delegate*<void>*)<Module>.DecodePointer(*(int*)__ponexitbegin_e);
				delegate*<void>* ptr2 = (delegate*<void>*)<Module>.DecodePointer(*(int*)__ponexitend_e);
				int num = (int)(ptr2 - ptr);
				if (*__pexit_list_size - 1U < (uint)num >> 2)
				{
					try
					{
						uint num2 = *__pexit_list_size * 4U;
						uint num3;
						if (num2 < 2048U)
						{
							num3 = num2;
						}
						else
						{
							num3 = 2048U;
						}
						IntPtr intPtr = new IntPtr((int)(num2 + num3));
						IntPtr intPtr2 = new IntPtr((void*)ptr);
						IntPtr intPtr3 = Marshal.ReAllocHGlobal(intPtr2, intPtr);
						IntPtr intPtr4 = intPtr3;
						ptr2 = (delegate*<void>*)((byte*)intPtr4.ToPointer() + num);
						ptr = (delegate*<void>*)intPtr4.ToPointer();
						uint num4 = *__pexit_list_size;
						uint num5;
						if (512U < num4)
						{
							num5 = 512U;
						}
						else
						{
							num5 = num4;
						}
						*__pexit_list_size = num4 + num5;
					}
					catch (OutOfMemoryException)
					{
						IntPtr intPtr5 = new IntPtr((int)(*__pexit_list_size * 4U + 8U));
						IntPtr intPtr6 = new IntPtr((void*)ptr);
						IntPtr intPtr7 = Marshal.ReAllocHGlobal(intPtr6, intPtr5);
						IntPtr intPtr8 = intPtr7;
						ptr2 = (intPtr8.ToPointer() - ptr) / (IntPtr)sizeof(delegate*<void>) + ptr2;
						ptr = (delegate*<void>*)intPtr8.ToPointer();
						*__pexit_list_size += 4U;
					}
				}
				*(int*)ptr2 = func;
				ptr2 += 4 / sizeof(delegate*<void>);
				system.Void_u0020() = func;
				*(int*)__ponexitbegin_e = <Module>.EncodePointer((void*)ptr);
				*(int*)__ponexitend_e = <Module>.EncodePointer((void*)ptr2);
			}
			catch (OutOfMemoryException)
			{
			}
			finally
			{
				<Module>.?A0xff04d0ec.__global_unlock();
			}
			if (system.Void_u0020() != null)
			{
				return 0;
			}
		}
		return -1;
	}

	// Token: 0x060000D3 RID: 211 RVA: 0x00007EA0 File Offset: 0x000072A0
	[SecurityCritical]
	internal unsafe static void _exit_callback()
	{
		if (<Module>.?A0xff04d0ec.__exit_list_size != 0U)
		{
			delegate*<void>* ptr = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.?A0xff04d0ec.__onexitbegin_m);
			delegate*<void>* ptr2 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.?A0xff04d0ec.__onexitend_m);
			if (ptr != -1 && ptr != null && ptr2 != null)
			{
				delegate*<void>* ptr3 = ptr;
				delegate*<void>* ptr4 = ptr2;
				for (;;)
				{
					ptr2 -= 4 / sizeof(delegate*<void>);
					if (ptr2 < ptr)
					{
						break;
					}
					if (*(int*)ptr2 != <Module>.EncodePointer(null))
					{
						IntPtr intPtr = <Module>.DecodePointer(*(int*)ptr2);
						*(int*)ptr2 = <Module>.EncodePointer(null);
						calli(System.Void(), intPtr);
						delegate*<void>* ptr5 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.?A0xff04d0ec.__onexitbegin_m);
						delegate*<void>* ptr6 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.?A0xff04d0ec.__onexitend_m);
						if (ptr3 != ptr5 || ptr4 != ptr6)
						{
							ptr3 = ptr5;
							ptr = ptr5;
							ptr4 = ptr6;
							ptr2 = ptr6;
						}
					}
				}
				IntPtr intPtr2 = new IntPtr((void*)ptr);
				Marshal.FreeHGlobal(intPtr2);
			}
			<Module>.?A0xff04d0ec.__dealloc_global_lock();
		}
	}

	// Token: 0x060000D4 RID: 212 RVA: 0x000080A8 File Offset: 0x000074A8
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static int _initatexit_m()
	{
		int num = 0;
		if (<Module>.?A0xff04d0ec.__alloc_global_lock() == 1)
		{
			<Module>.?A0xff04d0ec.__onexitbegin_m = (delegate*<void>*)<Module>.EncodePointer(Marshal.AllocHGlobal(128).ToPointer());
			<Module>.?A0xff04d0ec.__onexitend_m = <Module>.?A0xff04d0ec.__onexitbegin_m;
			<Module>.?A0xff04d0ec.__exit_list_size = 32U;
			num = 1;
		}
		return num;
	}

	// Token: 0x060000D5 RID: 213 RVA: 0x00007F44 File Offset: 0x00007344
	[SecurityCritical]
	internal unsafe static int _atexit_m(delegate*<void> func)
	{
		return <Module>._atexit_helper(<Module>.EncodePointer(func), &<Module>.?A0xff04d0ec.__exit_list_size, &<Module>.?A0xff04d0ec.__onexitend_m, &<Module>.?A0xff04d0ec.__onexitbegin_m);
	}

	// Token: 0x060000D6 RID: 214 RVA: 0x000080F0 File Offset: 0x000074F0
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static int _initatexit_app_domain()
	{
		if (<Module>.?A0xff04d0ec.__alloc_global_lock() == 1)
		{
			<Module>.__onexitbegin_app_domain = (delegate*<void>*)<Module>.EncodePointer(Marshal.AllocHGlobal(128).ToPointer());
			<Module>.__onexitend_app_domain = <Module>.__onexitbegin_app_domain;
			<Module>.__exit_list_size_app_domain = 32U;
		}
		return 1;
	}

	// Token: 0x060000D7 RID: 215 RVA: 0x00007F6C File Offset: 0x0000736C
	[SecurityCritical]
	[HandleProcessCorruptedStateExceptions]
	internal unsafe static void _app_exit_callback()
	{
		if (<Module>.__exit_list_size_app_domain != 0U)
		{
			delegate*<void>* ptr = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.__onexitbegin_app_domain);
			delegate*<void>* ptr2 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.__onexitend_app_domain);
			try
			{
				if (ptr != -1 && ptr != null && ptr2 != null)
				{
					delegate*<void>* ptr3 = ptr;
					delegate*<void>* ptr4 = ptr2;
					for (;;)
					{
						do
						{
							ptr2 -= 4 / sizeof(delegate*<void>);
						}
						while (ptr2 >= ptr && *(int*)ptr2 == <Module>.EncodePointer(null));
						if (ptr2 < ptr)
						{
							break;
						}
						delegate*<void> system.Void_u0020() = <Module>.DecodePointer(*(int*)ptr2);
						*(int*)ptr2 = <Module>.EncodePointer(null);
						calli(System.Void(), system.Void_u0020());
						delegate*<void>* ptr5 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.__onexitbegin_app_domain);
						delegate*<void>* ptr6 = (delegate*<void>*)<Module>.DecodePointer((void*)<Module>.__onexitend_app_domain);
						if (ptr3 != ptr5 || ptr4 != ptr6)
						{
							ptr3 = ptr5;
							ptr = ptr5;
							ptr4 = ptr6;
							ptr2 = ptr6;
						}
					}
				}
			}
			finally
			{
				IntPtr intPtr = new IntPtr((void*)ptr);
				Marshal.FreeHGlobal(intPtr);
				<Module>.?A0xff04d0ec.__dealloc_global_lock();
			}
		}
	}

	// Token: 0x060000D8 RID: 216
	[SecurityCritical]
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[SuppressUnmanagedCodeSecurity]
	[DllImport("KERNEL32.dll")]
	public unsafe static extern void* DecodePointer(void* _Ptr);

	// Token: 0x060000D9 RID: 217
	[ReliabilityContract(Consistency.WillNotCorruptState, Cer.Success)]
	[SecurityCritical]
	[SuppressUnmanagedCodeSecurity]
	[DllImport("KERNEL32.dll")]
	public unsafe static extern void* EncodePointer(void* _Ptr);

	// Token: 0x060000DA RID: 218 RVA: 0x00008134 File Offset: 0x00007534
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static int _initterm_e(delegate* unmanaged[Cdecl, Cdecl]<int>* pfbegin, delegate* unmanaged[Cdecl, Cdecl]<int>* pfend)
	{
		int num = 0;
		if (pfbegin < pfend)
		{
			while (num == 0)
			{
				uint num2 = (uint)(*(int*)pfbegin);
				if (num2 != 0U)
				{
					num = calli(System.Int32 modopt(System.Runtime.CompilerServices.CallConvCdecl)(), (IntPtr)num2);
				}
				pfbegin += 4 / sizeof(delegate* unmanaged[Cdecl, Cdecl]<int>);
				if (pfbegin >= pfend)
				{
					break;
				}
			}
		}
		return num;
	}

	// Token: 0x060000DB RID: 219 RVA: 0x00008164 File Offset: 0x00007564
	[DebuggerStepThrough]
	[SecurityCritical]
	internal unsafe static void _initterm(delegate* unmanaged[Cdecl, Cdecl]<void>* pfbegin, delegate* unmanaged[Cdecl, Cdecl]<void>* pfend)
	{
		if (pfbegin < pfend)
		{
			do
			{
				uint num = (uint)(*(int*)pfbegin);
				if (num != 0U)
				{
					calli(System.Void modopt(System.Runtime.CompilerServices.CallConvCdecl)(), (IntPtr)num);
				}
				pfbegin += 4 / sizeof(delegate* unmanaged[Cdecl, Cdecl]<void>);
			}
			while (pfbegin < pfend);
		}
	}

	// Token: 0x060000DC RID: 220 RVA: 0x0000818C File Offset: 0x0000758C
	[DebuggerStepThrough]
	internal static ModuleHandle <CrtImplementationDetails>.ThisModule.Handle()
	{
		return typeof(ThisModule).Module.ModuleHandle;
	}

	// Token: 0x060000DD RID: 221 RVA: 0x000081DC File Offset: 0x000075DC
	[DebuggerStepThrough]
	[SecurityCritical]
	[SecurityPermission(SecurityAction.Assert, UnmanagedCode = true)]
	internal unsafe static void _initterm_m(delegate*<void*>* pfbegin, delegate*<void*>* pfend)
	{
		if (pfbegin < pfend)
		{
			do
			{
				uint num = (uint)(*(int*)pfbegin);
				if (num != 0U)
				{
					void* ptr = calli(System.Void modopt(System.Runtime.CompilerServices.IsConst)*(), <Module>.<CrtImplementationDetails>.ThisModule.ResolveMethod<void\u0020const\u0020*\u0020__clrcall(void)>(num));
				}
				pfbegin += 4 / sizeof(delegate*<void*>);
			}
			while (pfbegin < pfend);
		}
	}

	// Token: 0x060000DE RID: 222 RVA: 0x000081B0 File Offset: 0x000075B0
	[SecurityCritical]
	[DebuggerStepThrough]
	internal unsafe static delegate*<void*> <CrtImplementationDetails>.ThisModule.ResolveMethod<void\u0020const\u0020*\u0020__clrcall(void)>(delegate*<void*> methodToken)
	{
		return <Module>.<CrtImplementationDetails>.ThisModule.Handle().ResolveMethodHandle(methodToken).GetFunctionPointer()
			.ToPointer();
	}

	// Token: 0x060000DF RID: 223 RVA: 0x000037F0 File Offset: 0x00002BF0
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void std.unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>.__autoclassinit2(unique_ptr<std::tuple<void\u0020(__cdecl*)(void)>,std::default_delete<std::tuple<void\u0020(__cdecl*)(void)>\u0020>\u0020>*, uint);

	// Token: 0x060000E0 RID: 224 RVA: 0x000084D1 File Offset: 0x000078D1
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _Cnd_do_broadcast_at_thread_exit();

	// Token: 0x060000E1 RID: 225 RVA: 0x00008516 File Offset: 0x00007916
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern uint _beginthreadex(void*, uint, delegate* unmanaged[Stdcall, Stdcall]<void*, uint>, void*, uint, uint*);

	// Token: 0x060000E2 RID: 226 RVA: 0x00001210 File Offset: 0x00000610
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void FixInvalidPtrCheck();

	// Token: 0x060000E3 RID: 227 RVA: 0x00008298 File Offset: 0x00007698
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int IsDebuggerPresent();

	// Token: 0x060000E4 RID: 228 RVA: 0x00008504 File Offset: 0x00007904
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void __CxxUnregisterExceptionObject(void*, int);

	// Token: 0x060000E5 RID: 229 RVA: 0x000084EC File Offset: 0x000078EC
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int __CxxQueryExceptionSize();

	// Token: 0x060000E6 RID: 230 RVA: 0x000084FE File Offset: 0x000078FE
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int __CxxDetectRethrow(void*);

	// Token: 0x060000E7 RID: 231 RVA: 0x000084F8 File Offset: 0x000078F8
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int __CxxRegisterExceptionObject(void*, void*);

	// Token: 0x060000E8 RID: 232 RVA: 0x000084F2 File Offset: 0x000078F2
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int __CxxExceptionFilter(void*, void*, int, void*);

	// Token: 0x060000E9 RID: 233 RVA: 0x00008483 File Offset: 0x00007883
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int WideCharToMultiByte(uint, uint, char*, int, sbyte*, int, sbyte*, int*);

	// Token: 0x060000EA RID: 234 RVA: 0x000084E6 File Offset: 0x000078E6
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* memmove(void*, void*, uint);

	// Token: 0x060000EB RID: 235 RVA: 0x00005F08 File Offset: 0x00005308
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void std._Xlength_error(sbyte*);

	// Token: 0x060000EC RID: 236 RVA: 0x00006062 File Offset: 0x00005462
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void delete[](void*, uint);

	// Token: 0x060000ED RID: 237 RVA: 0x00008214 File Offset: 0x00007614
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void __std_exception_destroy(__std_exception_data*);

	// Token: 0x060000EE RID: 238 RVA: 0x00008232 File Offset: 0x00007632
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void _CxxThrowException(void*, _s__ThrowInfo*);

	// Token: 0x060000EF RID: 239 RVA: 0x000063D3 File Offset: 0x000057D3
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* @new(uint);

	// Token: 0x060000F0 RID: 240 RVA: 0x0000823E File Offset: 0x0000763E
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _invalid_parameter_noinfo_noreturn();

	// Token: 0x060000F1 RID: 241 RVA: 0x00005F3F File Offset: 0x0000533F
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void delete(void*, uint);

	// Token: 0x060000F2 RID: 242 RVA: 0x000084D7 File Offset: 0x000078D7
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void _Thrd_sleep(xtime*);

	// Token: 0x060000F3 RID: 243 RVA: 0x000084B9 File Offset: 0x000078B9
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int _Thrd_detach(_Thrd_t);

	// Token: 0x060000F4 RID: 244 RVA: 0x000084B3 File Offset: 0x000078B3
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void std._Throw_Cpp_error(int);

	// Token: 0x060000F5 RID: 245 RVA: 0x00008244 File Offset: 0x00007644
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void terminate();

	// Token: 0x060000F6 RID: 246 RVA: 0x000084AD File Offset: 0x000078AD
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void std._Throw_C_error(int);

	// Token: 0x060000F7 RID: 247 RVA: 0x000084CB File Offset: 0x000078CB
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern long _Query_perf_counter();

	// Token: 0x060000F8 RID: 248 RVA: 0x000084C5 File Offset: 0x000078C5
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern long _Query_perf_frequency();

	// Token: 0x060000F9 RID: 249 RVA: 0x000084BF File Offset: 0x000078BF
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern long _Xtime_get_ticks();

	// Token: 0x060000FA RID: 250 RVA: 0x000046F0 File Offset: 0x00003AF0
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int sprintf_s<256>($ArrayType$$$BY0BAA@D*, sbyte*, __arglist);

	// Token: 0x060000FB RID: 251 RVA: 0x0000850A File Offset: 0x0000790A
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern sbyte* strstr(sbyte*, sbyte*);

	// Token: 0x060000FC RID: 252 RVA: 0x00008540 File Offset: 0x00007940
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int strncmp(sbyte*, sbyte*, uint);

	// Token: 0x060000FD RID: 253 RVA: 0x0000853A File Offset: 0x0000793A
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int isalnum(int);

	// Token: 0x060000FE RID: 254 RVA: 0x00004690 File Offset: 0x00003A90
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int sprintf_s(sbyte*, uint, sbyte*, __arglist);

	// Token: 0x060000FF RID: 255 RVA: 0x00008534 File Offset: 0x00007934
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int strcpy_s(sbyte*, uint, sbyte*);

	// Token: 0x06000100 RID: 256 RVA: 0x0000852E File Offset: 0x0000792E
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int iswalnum(ushort);

	// Token: 0x06000101 RID: 257 RVA: 0x00008528 File Offset: 0x00007928
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int isprint(int);

	// Token: 0x06000102 RID: 258 RVA: 0x00008522 File Offset: 0x00007922
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int isspace(int);

	// Token: 0x06000103 RID: 259 RVA: 0x0000851C File Offset: 0x0000791C
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern int tolower(int);

	// Token: 0x06000104 RID: 260 RVA: 0x00008262 File Offset: 0x00007662
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void free(void*);

	// Token: 0x06000105 RID: 261 RVA: 0x0000825C File Offset: 0x0000765C
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* malloc(uint);

	// Token: 0x06000106 RID: 262 RVA: 0x000083FF File Offset: 0x000077FF
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int CloseHandle(void*);

	// Token: 0x06000107 RID: 263 RVA: 0x000084A1 File Offset: 0x000078A1
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern uint GetLastError();

	// Token: 0x06000108 RID: 264 RVA: 0x0000849B File Offset: 0x0000789B
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int DeviceIoControl(void*, uint, void*, uint, void*, uint, uint*, _OVERLAPPED*);

	// Token: 0x06000109 RID: 265 RVA: 0x00008495 File Offset: 0x00007895
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* CreateFileA(sbyte*, uint, uint, _SECURITY_ATTRIBUTES*, uint, uint, void*);

	// Token: 0x0600010A RID: 266 RVA: 0x0000848F File Offset: 0x0000788F
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int VerifyVersionInfoW(_OSVERSIONINFOEXW*, uint, ulong);

	// Token: 0x0600010B RID: 267 RVA: 0x00008489 File Offset: 0x00007889
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern ulong VerSetConditionMask(ulong, uint, byte);

	// Token: 0x0600010C RID: 268 RVA: 0x00005AD0 File Offset: 0x00004ED0
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern sbyte* phmap.priv.EmptyGroup();

	// Token: 0x0600010D RID: 269 RVA: 0x000065A4 File Offset: 0x000059A4
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void delete[](void*);

	// Token: 0x0600010E RID: 270 RVA: 0x000084DD File Offset: 0x000078DD
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* new[](uint);

	// Token: 0x0600010F RID: 271 RVA: 0x00008510 File Offset: 0x00007910
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern int __FrameUnwindFilter(_EXCEPTION_POINTERS*);

	// Token: 0x06000110 RID: 272 RVA: 0x00008220 File Offset: 0x00007620
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void** __current_exception_context();

	// Token: 0x06000111 RID: 273 RVA: 0x0000821A File Offset: 0x0000761A
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void** __current_exception();

	// Token: 0x06000112 RID: 274 RVA: 0x00007330 File Offset: 0x00006730
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal unsafe static extern void* _getFiberPtrId();

	// Token: 0x06000113 RID: 275 RVA: 0x00008292 File Offset: 0x00007692
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _cexit();

	// Token: 0x06000114 RID: 276 RVA: 0x000084A7 File Offset: 0x000078A7
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.StdCall, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void Sleep(uint);

	// Token: 0x06000115 RID: 277 RVA: 0x00008546 File Offset: 0x00007946
	[SuppressUnmanagedCodeSecurity]
	[DllImport("", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
	[MethodImpl(MethodImplOptions.Unmanaged, MethodCodeType = MethodCodeType.Native)]
	internal static extern void abort();

	// Token: 0x06000116 RID: 278 RVA: 0x000065F6 File Offset: 0x000059F6
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void __security_init_cookie();

	// Token: 0x06000117 RID: 279 RVA: 0x000083B1 File Offset: 0x000077B1
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _Init_thread_wait(uint);

	// Token: 0x06000118 RID: 280 RVA: 0x0000836F File Offset: 0x0000776F
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _Init_thread_notify();

	// Token: 0x06000119 RID: 281 RVA: 0x000083A5 File Offset: 0x000077A5
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _Init_thread_unlock();

	// Token: 0x0600011A RID: 282 RVA: 0x00008363 File Offset: 0x00007763
	[SuppressUnmanagedCodeSecurity]
	[MethodImpl(MethodImplOptions.Unmanaged | MethodImplOptions.PreserveSig, MethodCodeType = MethodCodeType.Native)]
	internal static extern void _Init_thread_lock();

	// Token: 0x04000001 RID: 1 RVA: 0x000095C0 File Offset: 0x000081C0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BC@$$CBD ??_C@_0BC@EOODALEL@Unknown?5exception@;

	// Token: 0x04000002 RID: 2 RVA: 0x000095D4 File Offset: 0x000081D4
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BF@$$CBD ??_C@_0BF@KINCDENJ@bad?5array?5new?5length@;

	// Token: 0x04000003 RID: 3 RVA: 0x000095EC File Offset: 0x000081EC
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BA@$$CBD ??_C@_0BA@JFNIOLAK@string?5too?5long@;

	// Token: 0x04000004 RID: 4 RVA: 0x000095A4 File Offset: 0x000081A4
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY07$$CBD ??_C@_07NBCGADJA@Unknown@;

	// Token: 0x04000005 RID: 5 RVA: 0x00017CA8 File Offset: 0x000168A8
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_8 ??_R2?$_Ref_count_obj2@VProcessDescription@@@std@@8;

	// Token: 0x04000006 RID: 6 RVA: 0x00017D3C File Offset: 0x0001693C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_4 ??_R2CDataStore@@8;

	// Token: 0x04000007 RID: 7 RVA: 0x00019174 File Offset: 0x00017B74
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_26 ??_R0?AV_Ref_count_base@std@@@8;

	// Token: 0x04000008 RID: 8 RVA: 0x00017C74 File Offset: 0x00016874
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_4 ??_R2_Ref_count_base@std@@8;

	// Token: 0x04000009 RID: 9 RVA: 0x00017C7C File Offset: 0x0001687C
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3_Ref_count_base@std@@8;

	// Token: 0x0400000A RID: 10 RVA: 0x00017C8C File Offset: 0x0001688C
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@_Ref_count_base@std@@8;

	// Token: 0x0400000B RID: 11 RVA: 0x00017C58 File Offset: 0x00016858
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@?$_Ref_count_obj2@VProcessDescription@@@std@@8;

	// Token: 0x0400000C RID: 12 RVA: 0x00017D20 File Offset: 0x00016920
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@CDataStore@@8;

	// Token: 0x0400000D RID: 13 RVA: 0x00017CB4 File Offset: 0x000168B4
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3?$_Ref_count_obj2@VProcessDescription@@@std@@8;

	// Token: 0x0400000E RID: 14 RVA: 0x00019138 File Offset: 0x00017B38
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_50 ??_R0?AV?$_Ref_count_obj2@VProcessDescription@@@std@@@8;

	// Token: 0x0400000F RID: 15 RVA: 0x00017D44 File Offset: 0x00016944
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3CDataStore@@8;

	// Token: 0x04000010 RID: 16 RVA: 0x000191B0 File Offset: 0x00017BB0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_17 ??_R0?AVCDataStore@@@8;

	// Token: 0x04000011 RID: 17 RVA: 0x00017CC4 File Offset: 0x000168C4
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTICompleteObjectLocator ??_R4?$_Ref_count_obj2@VProcessDescription@@@std@@6B@;

	// Token: 0x04000012 RID: 18 RVA: 0x00017D54 File Offset: 0x00016954
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTICompleteObjectLocator ??_R4CDataStore@@6B@;

	// Token: 0x04000013 RID: 19 RVA: 0x00019030 File Offset: 0x00017A30
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY04Q6AXXZ ??_7?$_Ref_count_obj2@VProcessDescription@@@std@@6B@;

	// Token: 0x04000014 RID: 20 RVA: 0x000191D0 File Offset: 0x00017BD0
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '0'.
	internal static uint D3D9DEVICE_ENDSCENE_PTR;

	// Token: 0x04000015 RID: 21 RVA: 0x0001910C File Offset: 0x00017B0C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_31 ??_R0?AVbad_array_new_length@std@@@8;

	// Token: 0x04000016 RID: 22 RVA: 0x00017E30 File Offset: 0x00016A30
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@bad_array_new_length@std@@8;

	// Token: 0x04000017 RID: 23 RVA: 0x00017D7C File Offset: 0x0001697C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_12 ??_R2bad_array_new_length@std@@8;

	// Token: 0x04000018 RID: 24 RVA: 0x00017DFC File Offset: 0x000169FC
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3bad_array_new_length@std@@8;

	// Token: 0x04000019 RID: 25 RVA: 0x00017E1C File Offset: 0x00016A1C
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTICompleteObjectLocator ??_R4bad_array_new_length@std@@6B@;

	// Token: 0x0400001A RID: 26 RVA: 0x00019024 File Offset: 0x00017A24
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY02Q6AXXZ ??_7bad_array_new_length@std@@6B@;

	// Token: 0x0400001B RID: 27 RVA: 0x000190D4 File Offset: 0x00017AD4
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_20 ??_R0?AVbad_alloc@std@@@8;

	// Token: 0x0400001C RID: 28 RVA: 0x00017DB4 File Offset: 0x000169B4
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@bad_alloc@std@@8;

	// Token: 0x0400001D RID: 29 RVA: 0x00017D8C File Offset: 0x0001698C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_8 ??_R2bad_alloc@std@@8;

	// Token: 0x0400001E RID: 30 RVA: 0x00017E0C File Offset: 0x00016A0C
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3bad_alloc@std@@8;

	// Token: 0x0400001F RID: 31 RVA: 0x00017DE8 File Offset: 0x000169E8
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTICompleteObjectLocator ??_R4bad_alloc@std@@6B@;

	// Token: 0x04000020 RID: 32 RVA: 0x00019018 File Offset: 0x00017A18
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY02Q6AXXZ ??_7bad_alloc@std@@6B@;

	// Token: 0x04000021 RID: 33 RVA: 0x000190F0 File Offset: 0x00017AF0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_TypeDescriptor$_extraBytes_20 ??_R0?AVexception@std@@@8;

	// Token: 0x04000022 RID: 34 RVA: 0x00017D98 File Offset: 0x00016998
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIBaseClassDescriptor ??_R1A@?0A@EA@exception@std@@8;

	// Token: 0x04000023 RID: 35 RVA: 0x00017DD0 File Offset: 0x000169D0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__RTTIBaseClassArray$_extraBytes_4 ??_R2exception@std@@8;

	// Token: 0x04000024 RID: 36 RVA: 0x00017DD8 File Offset: 0x000169D8
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTIClassHierarchyDescriptor ??_R3exception@std@@8;

	// Token: 0x04000025 RID: 37 RVA: 0x00017D68 File Offset: 0x00016968
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__RTTICompleteObjectLocator ??_R4exception@std@@6B@;

	// Token: 0x04000026 RID: 38 RVA: 0x0001900C File Offset: 0x00017A0C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY02Q6AXXZ ??_7exception@std@@6B@;

	// Token: 0x04000027 RID: 39 RVA: 0x000183C0 File Offset: 0x00016FC0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $_s__CatchableTypeArray$_extraBytes_12 _CTA3?AVbad_array_new_length@std@@;

	// Token: 0x04000028 RID: 40 RVA: 0x00018408 File Offset: 0x00017008
	// Note: this field is marked with 'hasfieldrva'.
	internal static _s__ThrowInfo _TI3?AVbad_array_new_length@std@@;

	// Token: 0x04000029 RID: 41 RVA: 0x00019004 File Offset: 0x00017A04
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY01Q6AXXZ ??_7CDataStore@@6B@;

	// Token: 0x0400002A RID: 42 RVA: 0x000091E0 File Offset: 0x00007DE0
	// Note: this field is marked with 'hasfieldrva'.
	public unsafe static int** __unep@??$_Invoke@V?$tuple@P6AXXZ@std@@$0A@@thread@std@@$$FCGIPAX@Z;

	// Token: 0x0400002B RID: 43 RVA: 0x000091E4 File Offset: 0x00007DE4
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BE@$$CBD ??_C@_0BE@JBDFGGOO@?2?2?4?2PhysicalDrive?$CFd@;

	// Token: 0x0400002C RID: 44 RVA: 0x00009318 File Offset: 0x00007F18
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0GG@$$CBD ??_C@_0GG@CJCAMLAA@?$CFd?5ReadPhysicalDriveInNTUsingSm@;

	// Token: 0x0400002D RID: 45 RVA: 0x00009380 File Offset: 0x00007F80
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0GJ@$$CBD ??_C@_0GJ@IJMKHJPN@?6?$CFd?5ReadPhysicalDriveInNTUsingS@;

	// Token: 0x0400002E RID: 46 RVA: 0x000093EC File Offset: 0x00007FEC
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BL@$$CBD ??_C@_0BL@BENLMPB@SMART_RCV_DRIVE_DATA?5IOCTL@;

	// Token: 0x0400002F RID: 47 RVA: 0x000091F8 File Offset: 0x00007DF8
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0FL@$$CBD ??_C@_0FL@JJOBKBEG@?$CFd?5ReadPhysicalDriveInNTWithZer@;

	// Token: 0x04000030 RID: 48 RVA: 0x00009258 File Offset: 0x00007E58
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0GN@$$CBD ??_C@_0GN@GPCACGJP@?$CFs?5ReadPhysicalDriveInNTWithZer@;

	// Token: 0x04000031 RID: 49 RVA: 0x000092C8 File Offset: 0x00007EC8
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0DJ@$$CBD ??_C@_0DJ@LJNAKKAB@DeviceIOControl?5IOCTL_STORAGE_Q@;

	// Token: 0x04000032 RID: 50 RVA: 0x00009314 File Offset: 0x00007F14
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY02$$CBD ??_C@_02GMHACPFF@?$CFu@;

	// Token: 0x04000033 RID: 51 RVA: 0x000095A0 File Offset: 0x000081A0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00$$CBD ??_C@_00CNPNBAHC@@;

	// Token: 0x04000034 RID: 52 RVA: 0x00009408 File Offset: 0x00008008
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY04$$CBD ??_C@_04GCPHMKHD@WD?9W@;

	// Token: 0x04000035 RID: 53 RVA: 0x00009410 File Offset: 0x00008010
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY04$$CBD ??_C@_04FELOGBA@IBM?9@;

	// Token: 0x04000036 RID: 54 RVA: 0x00009418 File Offset: 0x00008018
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY06$$CBD ??_C@_06DMAMAECF@MAXTOR@;

	// Token: 0x04000037 RID: 55 RVA: 0x00009420 File Offset: 0x00008020
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY06$$CBD ??_C@_06PHJKODGL@Maxtor@;

	// Token: 0x04000038 RID: 56 RVA: 0x00009428 File Offset: 0x00008028
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY04$$CBD ??_C@_04EAMAMDGI@WDC?5@;

	// Token: 0x04000039 RID: 57 RVA: 0x000095FC File Offset: 0x000081FC
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY01$$CBD ??_C@_01CLKCMJKC@?5@;

	// Token: 0x0400003A RID: 58 RVA: 0x00009304 File Offset: 0x00007F04
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BA@$$CBD ??_C@_0BA@FOIKENOD@vector?5too?5long@;

	// Token: 0x0400003B RID: 59 RVA: 0x00019520 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '12894362189'.
	internal static ulong ?_OptionsStorage@?1??__local_stdio_printf_options@@YAPA_KXZ@4_KA;

	// Token: 0x0400003C RID: 60 RVA: 0x00019554 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal static flat_hash_map<enum\u0020GlobalOffsets,unsigned\u0020char\u0020*,phmap::Hash<enum\u0020GlobalOffsets>,phmap::EqualTo<enum\u0020GlobalOffsets>,std::allocator<std::pair<enum\u0020GlobalOffsets\u0020const\u0020,unsigned\u0020char\u0020*>\u0020>\u0020> ?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU?$Hash@W4GlobalOffsets@@@phmap@@U?$EqualTo@W4GlobalOffsets@@@3@V?$allocator@U?$pair@$$CBW4GlobalOffsets@@PAE@std@@@std@@@phmap@@A;

	// Token: 0x0400003D RID: 61 RVA: 0x000091C4 File Offset: 0x00007DC4
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0x347d919e.?FunctionMap$initializer$@ManagedDetourMgr@@0P6MXXZA;

	// Token: 0x0400003E RID: 62 RVA: 0x00009440 File Offset: 0x00008040
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0BA@$$CBC ?empty_group@?1??EmptyGroup@priv@phmap@@YAPACXZ@4QBCB;

	// Token: 0x0400003F RID: 63 RVA: 0x00019550 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal static unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020> ?Instance@DetourMgr@@2V?$unique_ptr@VDetourMgr@@U?$default_delete@VDetourMgr@@@std@@@std@@A;

	// Token: 0x04000040 RID: 64 RVA: 0x000091C0 File Offset: 0x00007DC0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0x347d919e.?Instance$initializer$@DetourMgr@@2P6MXXZA;

	// Token: 0x04000041 RID: 65 RVA: 0x0001952C File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal static BannedProccesses ?instance@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4V2@A;

	// Token: 0x04000042 RID: 66 RVA: 0x00019528 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '9460301'.
	internal static int ?$TSS0@?1??GetInstance@BannedProccesses@@SAAAV2@XZ@4HA;

	// Token: 0x04000043 RID: 67 RVA: 0x00009434 File Offset: 0x00008034
	// Note: this field is marked with 'hasfieldrva'.
	public unsafe static int** __unep@?AnticheatBannedProcessListHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z;

	// Token: 0x04000044 RID: 68 RVA: 0x00009430 File Offset: 0x00008030
	// Note: this field is marked with 'hasfieldrva'.
	public unsafe static int** __unep@?AnticheatInitializeHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z;

	// Token: 0x04000045 RID: 69 RVA: 0x0001956C File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '9460301'.
	internal static int __@@_PchSym_@00@UfhvihUtozwviUwlxfnvmghUtrgsfyUzhxvmhrlmOxfhglnwoohUhixUzhxvmhrlmOzmgrxsvzgUivovzhvUkxsOlyq@4B2008FD98C1DD4;

	// Token: 0x04000046 RID: 70 RVA: 0x00009484 File Offset: 0x00008084
	// Note: this field is marked with 'hasfieldrva'.
	internal static __s_GUID _GUID_cb2f6723_ab3a_11d2_9c40_00c04fa30a3e;

	// Token: 0x04000047 RID: 71
	[FixedAddressValueType]
	internal static Progress ?InitializedPerProcess@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A;

	// Token: 0x04000048 RID: 72 RVA: 0x000091B0 File Offset: 0x00007DB0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?InitializedPerProcess$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x04000049 RID: 73 RVA: 0x00009474 File Offset: 0x00008074
	// Note: this field is marked with 'hasfieldrva'.
	internal static __s_GUID _GUID_cb2f6722_ab3a_11d2_9c40_00c04fa30a3e;

	// Token: 0x0400004A RID: 74 RVA: 0x00009494 File Offset: 0x00008094
	// Note: this field is marked with 'hasfieldrva'.
	internal static __s_GUID _GUID_90f1a06c_7712_4762_86b5_7a5eba6bdb02;

	// Token: 0x0400004B RID: 75 RVA: 0x000094A4 File Offset: 0x000080A4
	// Note: this field is marked with 'hasfieldrva'.
	internal static __s_GUID _GUID_90f1a06e_7712_4762_86b5_7a5eba6bdb02;

	// Token: 0x0400004C RID: 76
	[FixedAddressValueType]
	internal static int ?Uninitialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA;

	// Token: 0x0400004D RID: 77
	[FixedAddressValueType]
	internal static Progress ?InitializedPerAppDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A;

	// Token: 0x0400004E RID: 78 RVA: 0x000198DC File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of 'True'.
	internal static bool ?Entered@DefaultDomain@<CrtImplementationDetails>@@2_NA;

	// Token: 0x0400004F RID: 79 RVA: 0x0001909C File Offset: 0x00017A9C
	// Note: this field is marked with 'hasfieldrva'.
	internal static TriBool ?hasNative@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A;

	// Token: 0x04000050 RID: 80 RVA: 0x000198DF File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of 'True'.
	internal static bool ?InitializedPerProcess@DefaultDomain@<CrtImplementationDetails>@@2_NA;

	// Token: 0x04000051 RID: 81 RVA: 0x000198D8 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '9460301'.
	internal static int ?Count@AllDomains@<CrtImplementationDetails>@@2HA;

	// Token: 0x04000052 RID: 82
	[FixedAddressValueType]
	internal static int ?Initialized@CurrentDomain@<CrtImplementationDetails>@@$$Q2HA;

	// Token: 0x04000053 RID: 83
	[FixedAddressValueType]
	internal static Progress ?InitializedNative@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A;

	// Token: 0x04000054 RID: 84 RVA: 0x000198DE File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of 'True'.
	internal static bool ?InitializedNativeFromCCTOR@DefaultDomain@<CrtImplementationDetails>@@2_NA;

	// Token: 0x04000055 RID: 85
	[FixedAddressValueType]
	internal static bool ?IsDefaultDomain@CurrentDomain@<CrtImplementationDetails>@@$$Q2_NA;

	// Token: 0x04000056 RID: 86
	[FixedAddressValueType]
	internal static Progress ?InitializedVtables@CurrentDomain@<CrtImplementationDetails>@@$$Q2W4Progress@2@A;

	// Token: 0x04000057 RID: 87 RVA: 0x000198DD File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of 'True'.
	internal static bool ?InitializedNative@DefaultDomain@<CrtImplementationDetails>@@2_NA;

	// Token: 0x04000058 RID: 88 RVA: 0x00019098 File Offset: 0x00017A98
	// Note: this field is marked with 'hasfieldrva'.
	internal static TriBool ?hasPerProcess@DefaultDomain@<CrtImplementationDetails>@@0W4TriBool@2@A;

	// Token: 0x04000059 RID: 89 RVA: 0x000091C8 File Offset: 0x00007DC8
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xc_mp_z;

	// Token: 0x0400005A RID: 90 RVA: 0x000091D0 File Offset: 0x00007DD0
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xi_vt_z;

	// Token: 0x0400005B RID: 91 RVA: 0x000091A4 File Offset: 0x00007DA4
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?IsDefaultDomain$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x0400005C RID: 92 RVA: 0x00009198 File Offset: 0x00007D98
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xc_ma_a;

	// Token: 0x0400005D RID: 93 RVA: 0x000091B8 File Offset: 0x00007DB8
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xc_ma_z;

	// Token: 0x0400005E RID: 94 RVA: 0x0000919C File Offset: 0x00007D9C
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?Initialized$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x0400005F RID: 95 RVA: 0x000091B4 File Offset: 0x00007DB4
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?InitializedPerAppDomain$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x04000060 RID: 96 RVA: 0x000091CC File Offset: 0x00007DCC
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xi_vt_a;

	// Token: 0x04000061 RID: 97 RVA: 0x000091AC File Offset: 0x00007DAC
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?InitializedNative$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x04000062 RID: 98 RVA: 0x000091BC File Offset: 0x00007DBC
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY00Q6MPBXXZ __xc_mp_a;

	// Token: 0x04000063 RID: 99 RVA: 0x000091A8 File Offset: 0x00007DA8
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?InitializedVtables$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x04000064 RID: 100 RVA: 0x000091A0 File Offset: 0x00007DA0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void> ?A0xcb795ccb.?Uninitialized$initializer$@CurrentDomain@<CrtImplementationDetails>@@$$Q2P6MXXZA;

	// Token: 0x04000065 RID: 101 RVA: 0x000094B4 File Offset: 0x000080B4
	// Note: this field is marked with 'hasfieldrva'.
	public unsafe static int** __unep@?DoNothing@DefaultDomain@<CrtImplementationDetails>@@$$FCGJPAX@Z;

	// Token: 0x04000066 RID: 102 RVA: 0x000094B8 File Offset: 0x000080B8
	// Note: this field is marked with 'hasfieldrva'.
	public unsafe static int** __unep@?_UninitializeDefaultDomain@LanguageSupport@<CrtImplementationDetails>@@$$FCGJPAX@Z;

	// Token: 0x04000067 RID: 103 RVA: 0x00019A14 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void>* ?A0xff04d0ec.__onexitbegin_m;

	// Token: 0x04000068 RID: 104 RVA: 0x00019A10 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '9460301'.
	internal static uint ?A0xff04d0ec.__exit_list_size;

	// Token: 0x04000069 RID: 105
	[FixedAddressValueType]
	internal unsafe static delegate*<void>* __onexitend_app_domain;

	// Token: 0x0400006A RID: 106
	[FixedAddressValueType]
	internal unsafe static void* ?_lock@AtExitLock@<CrtImplementationDetails>@@$$Q0PAXA;

	// Token: 0x0400006B RID: 107
	[FixedAddressValueType]
	internal static int ?_ref_count@AtExitLock@<CrtImplementationDetails>@@$$Q0HA;

	// Token: 0x0400006C RID: 108 RVA: 0x00019A18 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate*<void>* ?A0xff04d0ec.__onexitend_m;

	// Token: 0x0400006D RID: 109
	[FixedAddressValueType]
	internal static uint __exit_list_size_app_domain;

	// Token: 0x0400006E RID: 110
	[FixedAddressValueType]
	internal unsafe static delegate*<void>* __onexitbegin_app_domain;

	// Token: 0x0400006F RID: 111 RVA: 0x000190C8 File Offset: 0x00017AC8
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Cdecl, Cdecl]<void*> ?fpGetCurrent@ClientServices@@0P6APAXXZA;

	// Token: 0x04000070 RID: 112 RVA: 0x000190CC File Offset: 0x00017ACC
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<void*, CDataStore*, void> ?fpSendPacket2@ClientServices@@0P6EXPAXPAVCDataStore@@@ZA;

	// Token: 0x04000071 RID: 113 RVA: 0x000190C0 File Offset: 0x00017AC0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> ?fpFinalize@CDataStore@@0P6EXPAV1@@ZA;

	// Token: 0x04000072 RID: 114 RVA: 0x00009454 File Offset: 0x00008054
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY01Q6AXXZ ??_7type_info@@6B@;

	// Token: 0x04000073 RID: 115 RVA: 0x000190B8 File Offset: 0x00017AB8
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, CDataStore*> ?fpPutString@CDataStore@@0P6EAAV1@PAV1@PBD@ZA;

	// Token: 0x04000074 RID: 116 RVA: 0x000190B0 File Offset: 0x00017AB0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, int, CDataStore*> ?fpPutInt32@CDataStore@@0P6EAAV1@PAV1@H@ZA;

	// Token: 0x04000075 RID: 117 RVA: 0x000190B4 File Offset: 0x00017AB4
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, void> ?fpDestroy@CDataStore@@0P6EXPAV1@@ZA;

	// Token: 0x04000076 RID: 118 RVA: 0x000190BC File Offset: 0x00017ABC
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, CDataStore*> ?fpInit@CDataStore@@0P6EPAV1@PAV1@@ZA;

	// Token: 0x04000077 RID: 119 RVA: 0x000190D0 File Offset: 0x00017AD0
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Cdecl, Cdecl]<Opcodes, delegate* unmanaged[Cdecl, Cdecl]<void*, Opcodes, uint, CDataStore*, int>, void*, void> ?fpSetMessageHandler@ClientServices@@0P6AXW4Opcodes@@P6AHPAX0IPAVCDataStore@@@Z1@ZA;

	// Token: 0x04000078 RID: 120 RVA: 0x000190C4 File Offset: 0x00017AC4
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static delegate* unmanaged[Thiscall, Thiscall]<CDataStore*, sbyte*, uint, CDataStore*> ?fpGetString@CDataStore@@0P6EAAV1@PAV1@PADI@ZA;

	// Token: 0x04000079 RID: 121 RVA: 0x0000917C File Offset: 0x00007D7C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0A@P6AHXZ __xi_z;

	// Token: 0x0400007A RID: 122 RVA: 0x000198A8 File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal static __scrt_native_startup_state __scrt_current_native_startup_state;

	// Token: 0x0400007B RID: 123 RVA: 0x000198AC File Offset: 0x00000000
	// Note: this field is marked with 'hasfieldrva'.
	internal unsafe static void* __scrt_native_startup_lock;

	// Token: 0x0400007C RID: 124 RVA: 0x0000916C File Offset: 0x00007D6C
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0A@P6AXXZ __xc_a;

	// Token: 0x0400007D RID: 125 RVA: 0x00009174 File Offset: 0x00007D74
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0A@P6AHXZ __xi_a;

	// Token: 0x0400007E RID: 126 RVA: 0x00019090 File Offset: 0x00017A90
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '4294967295'.
	internal static uint __scrt_native_dllmain_reason;

	// Token: 0x0400007F RID: 127 RVA: 0x00009170 File Offset: 0x00007D70
	// Note: this field is marked with 'hasfieldrva'.
	internal static $ArrayType$$$BY0A@P6AXXZ __xc_z;

	// Token: 0x04000080 RID: 128 RVA: 0x000190A8 File Offset: 0x00017AA8
	// Note: this field is marked with 'hasfieldrva' and has an initial value of '-2147483648'.
	internal static int _Init_global_epoch;
}
